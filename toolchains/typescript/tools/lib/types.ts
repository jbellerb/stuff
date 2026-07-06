export interface Dep {
  specifier: string;
  transpiled: string;
  main?: string | null;
}
