import { Buffer } from "node:buffer";
import { create, fromBinary, toBinary } from "npm:@bufbuild/protobuf";
import { Server, ServerCredentials } from "npm:@grpc/grpc-js";
import {
  ExecuteResponseSchema,
  Worker,
} from "npm:buck2-worker-proto/worker_pb.js";
import ts from "npm:typescript";

import { canonicalize, matchDep } from "./lib/util.ts";

import type { Message } from "npm:@bufbuild/protobuf";
import type {
  sendUnaryData,
  ServerUnaryCall,
  ServiceDefinition,
  UntypedServiceImplementation,
} from "npm:@grpc/grpc-js";
import type {
  ExecuteCommand,
  ExecuteResponse,
} from "npm:buck2-worker-proto/worker_pb.js";

import type { Dep } from "./lib/types.ts";

interface Config {
  cell: string;
  package: string;
  srcs: Record<string, string>;
  deps: Dep[];
  packages: { pkg: string; path: string }[];
  lib?: string[];
  alias?: Record<string, string>;
  strict?: boolean;
}

const cwd = Deno.cwd();
const abs = (path: string): string =>
  path.startsWith("/") ? path : `${cwd}/${path}`;

// ROOT is the virtual project directory
const ROOT = "/__project__";

// Parsed source files are cached across worker requests. tsc mutates source
// files while binding, and module resolution happens relative to the file's
// name, so entries are only shared when both the virtual path and the on-disk
// path match.
interface CachedSourceFile {
  sourceFile: ts.SourceFile;
  mtime: number | undefined;
  size: number;
}
const sourceFiles = new Map<string, CachedSourceFile>();
const SOURCE_FILE_LIMIT = 1024;

const getCachedSourceFile = (
  real: (path: string) => string | undefined,
  fileName: string,
  languageVersionOrOptions: ts.ScriptTarget | ts.CreateSourceFileOptions,
  onError?: (message: string) => void,
  shouldCreateNewSourceFile?: boolean,
): ts.SourceFile | undefined => {
  const realPath = real(fileName);
  if (realPath === undefined) return undefined;

  let stat: Deno.FileInfo;
  try {
    stat = Deno.statSync(realPath);
  } catch {
    return undefined;
  }

  const version =
    typeof languageVersionOrOptions === "object"
      ? `${languageVersionOrOptions.languageVersion}.${
          languageVersionOrOptions.impliedNodeFormat ?? ""
        }`
      : languageVersionOrOptions;
  const key = `${version}\n${realPath}\n${fileName}`;
  const cached = sourceFiles.get(key);
  if (
    !shouldCreateNewSourceFile &&
    cached !== undefined &&
    cached.mtime === stat.mtime?.getTime() &&
    cached.size === stat.size
  ) {
    sourceFiles.delete(key);
    sourceFiles.set(key, cached);
    return cached.sourceFile;
  }

  const text = ts.sys.readFile(realPath);
  if (text === undefined) return undefined;
  let sourceFile: ts.SourceFile;
  try {
    sourceFile = ts.createSourceFile(fileName, text, languageVersionOrOptions);
  } catch (e) {
    onError?.(String(e));
    return undefined;
  }

  sourceFiles.delete(key);
  sourceFiles.set(key, {
    sourceFile,
    mtime: stat.mtime?.getTime(),
    size: stat.size,
  });
  if (sourceFiles.size > SOURCE_FILE_LIMIT) {
    const oldest = sourceFiles.keys().next().value;
    if (oldest !== undefined) sourceFiles.delete(oldest);
  }
  return sourceFile;
};

// this is incompatible with resolveLabel from util.ts because TypeScript
// requires this function to be synchronous
const resolveLabel = (
  config: Config,
  target: string,
): ts.ResolvedModuleWithFailedLookupLocations | undefined => {
  // return early if this can't possibly be a buck2 target
  if (!target.startsWith(":") && !target.includes("//")) {
    return undefined;
  }

  const label = canonicalize(target, config.cell, config.package);
  const matched = matchDep(label, config.deps);
  if (matched === undefined) {
    return undefined;
  }
  const subpath = label.slice(matched.specifier.length + 1);

  const root = abs(matched.transpiled);
  const candidates = !subpath
    ? matched.main != null
      ? [`${root}/${matched.main}.d.ts`]
      : []
    : // remap .js to .d.ts since we only care about types
      [`${root}/${subpath.replace(/\.js$/, "")}.d.ts`, `${root}/${subpath}`];
  const found = candidates.find((path) => ts.sys.fileExists(path));

  return {
    resolvedModule: found
      ? {
          resolvedFileName: found,
          extension: ts.Extension.Dts,
          isExternalLibraryImport: true,
        }
      : undefined,
  };
};

const build = (
  config: Config,
  outDir: string,
): { failed: boolean; output: string } => {
  const mounts = new Map<string, string>(
    Object.entries(config.srcs).map(([name, target]) => [name, abs(target)]),
  );
  for (const { pkg, path } of config.packages) {
    mounts.set(`node_modules/${pkg}`, abs(path));
  }

  // ROOT and every ancestor directory of a mount exist as virtual directories
  const dirs = new Set<string>([ROOT]);
  for (const name of mounts.keys()) {
    for (let i = name.indexOf("/"); i !== -1; i = name.indexOf("/", i + 1)) {
      dirs.add(`${ROOT}/${name.slice(0, i)}`);
    }
  }

  const real = (path: string): string | undefined => {
    if (path !== ROOT && !path.startsWith(`${ROOT}/`)) {
      return path;
    }

    let name = path.slice(ROOT.length + 1);
    let suffix = "";
    while (name !== "") {
      if (mounts.has(name)) {
        return mounts.get(name) + suffix;
      }

      const slash = name.lastIndexOf("/");
      if (slash === -1) {
        break;
      }

      suffix = name.slice(slash) + suffix;
      name = name.slice(0, slash);
    }

    return undefined;
  };

  const { options, errors } = ts.convertCompilerOptionsFromJson(
    {
      outDir: abs(outDir),
      rootDir: ROOT,
      module: "esnext",
      moduleResolution: "bundler",
      // always emit esnext. the bundler downlevels to the final target
      target: "esnext",
      declaration: true,
      strict: config.strict ?? true,
      isolatedModules: true,
      noEmitOnError: true,
      // rewrite imports so the bundler consumes the .js files directly
      rewriteRelativeImportExtensions: true,
      // deps were already checked when their own library target built
      skipLibCheck: true,
      types: [],
      lib: config.lib,
    },
    ROOT,
  );

  const system: ts.System = {
    ...ts.sys,
    fileExists(path) {
      const r = real(path);
      return r !== undefined && ts.sys.fileExists(r);
    },
    readFile(path) {
      const r = real(path);
      return r === undefined ? undefined : ts.sys.readFile(r);
    },
    directoryExists(path) {
      if (dirs.has(path)) return true;
      const r = real(path);
      return r !== undefined && ts.sys.directoryExists(r);
    },
    // automatic @types inclusion is disabled, so nothing actually enumerates
    // directories. Mounts would be invisible here.
    getDirectories: () => [],
    realpath(path) {
      return path === ROOT || path.startsWith(`${ROOT}/`)
        ? path
        : (ts.sys.realpath?.(path) ?? "");
    },
  };

  const alias = config.alias ?? {};
  const host = ts.createIncrementalCompilerHost(options, system);
  host.getSourceFile = (...args) => getCachedSourceFile(real, ...args);
  host.resolveModuleNameLiterals = (
    literals,
    containingFile,
    redirected,
    opts,
  ) =>
    literals.map((literal) => {
      const target = alias[literal.text] ?? literal.text;
      return (
        resolveLabel(config, target) ??
        ts.resolveModuleName(
          target,
          containingFile,
          opts,
          system,
          undefined,
          redirected,
        )
      );
    });

  const program = ts.createProgram({
    rootNames: Object.keys(config.srcs).map((file) => `${ROOT}/${file}`),
    options,
    host,
  });

  const emitResult = program.emit();
  const diagnostics = ts.sortAndDeduplicateDiagnostics([
    ...errors,
    ...ts.getPreEmitDiagnostics(program),
    ...emitResult.diagnostics,
  ]);

  const format = Deno.noColor
    ? ts.formatDiagnostics
    : ts.formatDiagnosticsWithColorAndContext;
  return {
    failed: diagnostics.some((d) => d.category === ts.DiagnosticCategory.Error),
    output: diagnostics.length > 0 ? format(diagnostics, host) : "",
  };
};

// create a grpc-js service definition from a protobuf-es service descriptor.
// Adapted from
// https://github.com/connectrpc/connect-es/blob/3888ec37d7050863acefbb3b4a9c5e30367de8f6/packages/connect-web-test/src/nodeonly/create-grpc-definition.ts.
const grpcServiceDefinition = (service: typeof Worker): ServiceDefinition =>
  Object.fromEntries(
    service.methods.map((method) => [
      method.localName,
      {
        path: `/${service.typeName}/${method.name}`,
        originalName: method.name,
        requestStream:
          method.methodKind === "client_streaming" ||
          method.methodKind === "bidi_streaming",
        responseStream:
          method.methodKind === "server_streaming" ||
          method.methodKind === "bidi_streaming",
        requestSerialize: (value: Message) =>
          Buffer.from(toBinary(method.input, value)),
        requestDeserialize: (bytes: Buffer) => fromBinary(method.input, bytes),
        responseSerialize: (value: Message) =>
          Buffer.from(toBinary(method.output, value)),
        responseDeserialize: (bytes: Buffer) =>
          fromBinary(method.output, bytes),
      },
    ]),
  ) as ServiceDefinition;

const execute = (command: ExecuteCommand): ExecuteResponse => {
  const respond = (exitCode: number, stderr: string): ExecuteResponse =>
    create(ExecuteResponseSchema, { exitCode, stderr });
  try {
    const [configPath, outDir] = command.argv.map((arg) =>
      new TextDecoder().decode(arg),
    );
    const config = JSON.parse(Deno.readTextFileSync(configPath)) as Config;
    const { failed, output } = build(config, outDir);
    return respond(failed ? 1 : 0, output);
  } catch (e) {
    return respond(
      3,
      `tsc_build worker: ${e instanceof Error ? e.stack : String(e)}`,
    );
  }
};

const serve = (socketPath: string): void => {
  const server = new Server();
  const implementation: UntypedServiceImplementation = {
    execute: (
      call: ServerUnaryCall<ExecuteCommand, ExecuteResponse>,
      callback: sendUnaryData<ExecuteResponse>,
    ) => callback(null, execute(call.request)),
  };
  server.addService(grpcServiceDefinition(Worker), implementation);
  server.bindAsync(
    `unix:${socketPath}`,
    ServerCredentials.createInsecure(),
    (err) => {
      if (err !== null) {
        console.error(`tsc_build worker: ${err.message}`);
        Deno.exit(1);
      }
    },
  );
};

const socketPath = Deno.env.get("WORKER_SOCKET");
if (socketPath !== undefined) {
  serve(socketPath);
} else {
  const [configPath, outDir] = Deno.args;
  const config = JSON.parse(await Deno.readTextFile(configPath)) as Config;
  const { failed, output } = build(config, outDir);
  if (output !== "") console.error(output);
  Deno.exit(failed ? 1 : 0);
}
