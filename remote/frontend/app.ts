import { type ITerminalOptions, Terminal } from "@xterm/xterm";

import xtermStylesheet from ":xterm-css";

const RECONNECT_BASE_DELAY = 500;
const RECONNECT_MAX_DELAY = 30000;
const RECONNECT_MAX_RETRIES = 10;

type Node<T> = {
  value: T;
  next: Node<T> | null;
};

class Queue<T> {
  #head: Node<T> | null = null;
  #tail: Node<T> | null = null;
  #length = 0;

  pushBack(value: T) {
    const node = { value, next: null };
    if (this.#tail) {
      this.#tail.next = node;
    } else {
      this.#head = node;
    }
    this.#tail = node;
    this.#length += 1;
  }

  popFront(): T | undefined {
    if (!this.#head) {
      return undefined;
    }

    const value = this.#head.value;
    this.#head = this.#head.next;
    if (!this.#head) {
      this.#tail = null;
    }
    this.#length -= 1;

    return value;
  }

  get length() {
    return this.#length;
  }
}

class RemoteTerminal extends HTMLElement {
  #terminal: Terminal;
  #container: HTMLDivElement | undefined;
  #resizeObserver: ResizeObserver;

  #ws: WebSocket | null = null;
  #wsReconnectAttempts: number = 0;
  #wsPending: Queue<string | ArrayBuffer | ArrayBufferView<ArrayBuffer>> =
    new Queue();

  static #textEncoder = new TextEncoder();

  constructor() {
    super();
    this.#terminal = new Terminal();
    this.#resizeObserver = new ResizeObserver(this.#handleResize.bind(this));
  }

  connectedCallback() {
    const shadow = this.attachShadow({ mode: "open" });
    shadow.adoptedStyleSheets = [xtermStylesheet];

    this.#container = document.createElement("div");
    this.#container.style.width = "100%";
    this.#container.style.height = "100%";
    shadow.appendChild(this.#container);

    this.#terminal.open(this.#container);
    this.#resizeObserver.observe(this.#container);
    this.#handleResize();

    this.#terminal.onData((data: string) => {
      this.#send(RemoteTerminal.#textEncoder.encode(data));
    });

    const url = new URL(
      this.getAttribute("data-url") ||
        `${
          window.location.hostname === "localhost" ? "ws" : "wss"
        }://${window.location.host}${window.location.pathname}`,
    );
    this.#connect(url);
  }

  #connect(url: URL) {
    const [width, height] = this.#terminalSize();
    const params = new URLSearchParams();
    params.set("term", "xterm-256color");
    params.set("cols", String(this.#terminal.cols || 80));
    params.set("rows", String(this.#terminal.rows || 24));
    params.set("width", String(width || 640));
    params.set("height", String(height || 480));

    this.#ws = new WebSocket(
      `${url.origin}${url.pathname}?${params}`,
      "remote.v1",
    );
    this.#ws.binaryType = "arraybuffer";

    this.#ws.addEventListener("open", () => {
      this.#wsReconnectAttempts = 0;

      let data = this.#wsPending.popFront();
      while (data !== undefined) {
        this.#ws?.send(data);
        data = this.#wsPending.popFront();
      }
    });

    this.#ws.addEventListener("close", (event) => {
      if (
        event.code === 1000 ||
        this.#wsReconnectAttempts >= RECONNECT_MAX_RETRIES
      ) {
        // TODO: display error on reconnect failure
        this.#ws = null;
        return;
      }

      // TODO: display warning when reconnecting
      const delay = Math.min(
        RECONNECT_BASE_DELAY * 2 ** this.#wsReconnectAttempts++,
        RECONNECT_MAX_DELAY,
      ) *
        (0.5 + Math.random() * 0.5);
      setTimeout(() => this.#connect(url), Math.floor(delay));
    });

    this.#ws.addEventListener("message", (event) => {
      this.#terminal.write(new Uint8Array(event.data as ArrayBuffer));
    });
  }

  disconnectedCallback() {
    this.#resizeObserver.disconnect();
    if (this.#ws) {
      const state = this.#ws.readyState;
      if (state !== WebSocket.CLOSING && state !== WebSocket.CLOSED) {
        this.#ws.close();
      }
      this.#ws = null;
    }
  }

  #send(data: string | ArrayBuffer | ArrayBufferView<ArrayBuffer>) {
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#ws.send(data);
    } else {
      this.#wsPending.pushBack(data);
    }
  }

  #terminalSize(): [number, number] {
    // TODO: remove manual typing when the scrollbar options are added to
    // ITerminalOptions
    const options: ITerminalOptions & {
      scrollbar?: { showScrollbar?: boolean; width?: number };
    } = this.#terminal.options;
    const showScrollbar =
      (this.#container && options.scrollbar?.showScrollbar) ?? true;
    const scrollbarWidth = options.scrollback === 0 || !showScrollbar
      ? 0
      : (options.scrollbar?.width ?? 14);

    return [
      (this.#container?.clientWidth ?? 0) - scrollbarWidth,
      this.#container?.clientHeight ?? 0,
    ];
  }

  #handleResize() {
    // TODO: replace this with the dimensions API once the next xterm.js
    // version is released.
    const dims = (
      this.#terminal as unknown as {
        _core: {
          _renderService: {
            dimensions: { css: { cell: { width: number; height: number } } };
          };
        };
      }
    )._core._renderService.dimensions;

    const [width, height] = this.#terminalSize();
    const cols = Math.floor(width / dims.css.cell.width);
    const rows = Math.floor(height / dims.css.cell.height);

    this.#terminal.resize(cols, rows);
    if (this.#ws?.readyState === WebSocket.OPEN) {
      this.#send(
        JSON.stringify({
          type: "window-change",
          cols,
          rows,
          width: this.clientWidth,
          height: this.clientHeight,
        }),
      );
    }
  }
}

customElements.define("remote-terminal", RemoteTerminal);
