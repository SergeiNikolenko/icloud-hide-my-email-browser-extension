import {
  ActiveInputElementWriteData,
  GenerationResponseData,
  Message,
  MessageType,
  ReservationRequestData,
  ReservationResponseData,
} from '../../messages';
import { v4 as uuidv4 } from 'uuid';
import browser from 'webextension-polyfill';
import { getBrowserStorageValue } from '../../storage';

const EMAIL_INPUT_QUERY_STRING = [
  'input[type="email"]',
  'input[name="email"]',
  'input[id="email"]',
  'input[autocomplete~="email"]',
].join(', ');

const LOADING_COPY = 'Hide My Email';

// The suggestion lives in a closed shadow root, so neither the page's CSS can
// restyle it nor ours can leak into the page. It mimics Safari's autofill
// suggestion menu: a neutral glass popover holding a single row.
const BUTTON_STYLE = `
:host {
  all: initial;
  position: fixed;
  z-index: 2147483647;
  display: none;
}
:host([data-open]) { display: block; }
.menu {
  box-sizing: border-box;
  padding: 5px;
  border-radius: 12px;
  background: rgb(246 246 246 / 0.78);
  -webkit-backdrop-filter: blur(24px) saturate(180%);
  backdrop-filter: blur(24px) saturate(180%);
  box-shadow: 0 0 0 0.5px rgb(0 0 0 / 0.16), inset 0 0.5px 0 rgb(255 255 255 / 0.7), 0 8px 24px rgb(0 0 0 / 0.16), 0 1px 3px rgb(0 0 0 / 0.08);
  animation: enter 160ms cubic-bezier(0.32, 0.72, 0, 1);
}
button {
  all: unset;
  box-sizing: border-box;
  display: flex;
  align-items: center;
  gap: 7px;
  width: 100%;
  height: 28px;
  padding: 0 8px;
  border-radius: 7px;
  font: 400 13px/16px -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, 'Segoe UI', Roboto, sans-serif;
  color: rgb(0 0 0 / 0.85);
  cursor: default;
  transition: background-color 100ms ease-out;
}
button:hover:not([aria-disabled='true']) { background: rgb(0 0 0 / 0.07); }
button[data-state='loading'] .text { color: rgb(0 0 0 / 0.5); }
button[data-state='error'] .text { color: #ff3b30; }
svg { flex: none; width: 15px; height: 15px; color: rgb(0 0 0 / 0.5); }
.text { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
@media (prefers-color-scheme: dark) {
  .menu {
    background: rgb(40 40 40 / 0.78);
    box-shadow: 0 0 0 0.5px rgb(0 0 0 / 0.6), inset 0 0 0 0.5px rgb(255 255 255 / 0.12), 0 8px 28px rgb(0 0 0 / 0.45);
  }
  button { color: rgb(255 255 255 / 0.86); }
  button:hover:not([aria-disabled='true']) { background: rgb(255 255 255 / 0.1); }
  button[data-state='loading'] .text { color: rgb(255 255 255 / 0.55); }
  button[data-state='error'] .text { color: #ff453a; }
  svg { color: rgb(255 255 255 / 0.55); }
}
@keyframes enter { from { opacity: 0; transform: translateY(-3px); } }
@media (prefers-reduced-motion: reduce) { .menu { animation: none; } button { transition: none; } }
`;

const SVG_NS = 'http://www.w3.org/2000/svg';

const makeMailIcon = (): SVGSVGElement => {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '1.75');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  const rect = document.createElementNS(SVG_NS, 'rect');
  rect.setAttribute('x', '2');
  rect.setAttribute('y', '4');
  rect.setAttribute('width', '20');
  rect.setAttribute('height', '16');
  rect.setAttribute('rx', '3');
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', 'm22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7');
  svg.append(rect, path);
  return svg;
};

type ButtonState = 'loading' | 'ready' | 'error';

const isWritableInput = (el: HTMLInputElement): boolean =>
  !el.disabled && !el.readOnly && el.type !== 'hidden';

const writeValue = (
  el: HTMLInputElement | HTMLTextAreaElement,
  value: string
): void => {
  el.value = value;
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
};

const deepActiveElement = (): Element | null => {
  let active = document.activeElement;
  while (active?.shadowRoot?.activeElement) {
    active = active.shadowRoot.activeElement;
  }
  return active;
};

const createFieldButton = () => {
  const host = document.createElement('div');
  const shadow = host.attachShadow({ mode: 'closed' });
  const style = document.createElement('style');
  style.textContent = BUTTON_STYLE;
  const button = document.createElement('button');
  button.type = 'button';
  button.tabIndex = -1;
  const text = document.createElement('span');
  text.className = 'text';
  button.append(makeMailIcon(), text);
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.append(button);
  shadow.append(style, menu);

  let anchor: HTMLInputElement | undefined;
  let frame = 0;

  const place = () => {
    frame = 0;
    if (!anchor?.isConnected) {
      return;
    }
    const rect = anchor.getBoundingClientRect();
    const width = Math.min(Math.max(rect.width, 240), 420);
    const left = Math.min(
      Math.max(rect.left, 8),
      window.innerWidth - width - 8
    );
    // The menu is 38px tall and floats 6px off the field.
    const below = rect.bottom + 6;
    const top =
      below + 46 > window.innerHeight ? Math.max(rect.top - 44, 8) : below;
    host.style.left = `${left}px`;
    host.style.top = `${top}px`;
    host.style.width = `${width}px`;
  };

  const schedulePlace = () => {
    if (!frame) {
      frame = requestAnimationFrame(place);
    }
  };

  return {
    button,
    get anchor() {
      return anchor;
    },
    show(input: HTMLInputElement) {
      anchor = input;
      if (!host.isConnected) {
        document.documentElement.append(host);
      }
      host.setAttribute('data-open', '');
      place();
      window.addEventListener('scroll', schedulePlace, {
        capture: true,
        passive: true,
      });
      window.addEventListener('resize', schedulePlace, { passive: true });
    },
    hide() {
      anchor = undefined;
      host.removeAttribute('data-open');
      window.removeEventListener('scroll', schedulePlace, { capture: true });
      window.removeEventListener('resize', schedulePlace);
    },
    setState(state: ButtonState, copy: string) {
      button.dataset.state = state;
      button.setAttribute('aria-disabled', String(state !== 'ready'));
      button.title = copy;
      text.textContent = copy;
    },
  };
};

export default async function main(): Promise<void> {
  const options = await getBrowserStorageValue('iCloudHmeOptions');
  const isButtonEnabled = options?.autofill?.button !== false;

  const fieldButton = isButtonEnabled ? createFieldButton() : undefined;
  // Inputs that already received an address; the button is not offered again.
  const filledInputs = new WeakSet<HTMLInputElement>();
  let lastFocusedInput: HTMLInputElement | undefined;
  let requestId: string | undefined;
  let generatedHme: string | undefined;

  const matchEmailInput = (target: EventTarget | null) =>
    target instanceof HTMLInputElement &&
    target.matches(EMAIL_INPUT_QUERY_STRING) &&
    isWritableInput(target)
      ? target
      : undefined;

  const onInputFocus = (input: HTMLInputElement) => {
    lastFocusedInput = input;
    if (!fieldButton || filledInputs.has(input)) {
      return;
    }
    requestId = uuidv4();
    generatedHme = undefined;
    fieldButton.setState('loading', `${LOADING_COPY}…`);
    fieldButton.show(input);
    browser.runtime
      .sendMessage({ type: MessageType.GenerateRequest, data: requestId })
      .catch(console.debug);
  };

  document.addEventListener(
    'focusin',
    (ev) => {
      const input = matchEmailInput(ev.composedPath()[0] ?? null);
      if (input) {
        onInputFocus(input);
      }
    },
    true
  );

  document.addEventListener(
    'focusout',
    (ev) => {
      if (fieldButton && ev.composedPath()[0] === fieldButton.anchor) {
        fieldButton.hide();
        requestId = undefined;
      }
    },
    true
  );

  const initiallyFocused = matchEmailInput(deepActiveElement());
  if (initiallyFocused) {
    onInputFocus(initiallyFocused);
  }

  fieldButton?.button.addEventListener('mousedown', (ev) => {
    // Keep the focus on the input so that the button is not hidden.
    ev.preventDefault();
    if (generatedHme === undefined || requestId === undefined) {
      return;
    }
    fieldButton.setState('loading', generatedHme);
    browser.runtime
      .sendMessage({
        type: MessageType.ReservationRequest,
        data: {
          hme: generatedHme,
          label: window.location.hostname,
          elementId: requestId,
        },
      } as Message<ReservationRequestData>)
      .catch(console.debug);
  });

  browser.runtime.onMessage.addListener((uncastedMessage: unknown) => {
    const message = uncastedMessage as Message<unknown>;

    switch (message.type) {
      case MessageType.Autofill: {
        const hme = message.data as string;
        const targets = lastFocusedInput?.isConnected
          ? [lastFocusedInput]
          : Array.from(
              document.querySelectorAll<HTMLInputElement>(
                EMAIL_INPUT_QUERY_STRING
              )
            ).filter(isWritableInput);
        targets.forEach((input) => {
          writeValue(input, hme);
          filledInputs.add(input);
        });
        fieldButton?.hide();
        break;
      }
      case MessageType.GenerateResponse: {
        const { hme, elementId, error } =
          message.data as GenerationResponseData;
        if (!fieldButton || elementId !== requestId) {
          break;
        }
        if (error) {
          fieldButton.setState('error', error);
        } else if (hme) {
          generatedHme = hme;
          fieldButton.setState('ready', hme);
        }
        break;
      }
      case MessageType.ReservationResponse: {
        const { hme, error, elementId } =
          message.data as ReservationResponseData;
        const input = fieldButton?.anchor;
        if (!fieldButton || elementId !== requestId || !input) {
          break;
        }
        if (error) {
          fieldButton.setState('error', error);
        } else if (hme) {
          writeValue(input, hme);
          filledInputs.add(input);
          fieldButton.hide();
          requestId = undefined;
        }
        break;
      }
      case MessageType.ActiveInputElementWrite: {
        const { text, copyToClipboard } =
          message.data as ActiveInputElementWriteData;
        const activeElement = deepActiveElement();
        if (
          activeElement instanceof HTMLInputElement ||
          activeElement instanceof HTMLTextAreaElement
        ) {
          writeValue(activeElement, text);
          if (activeElement instanceof HTMLInputElement) {
            filledInputs.add(activeElement);
          }
          fieldButton?.hide();
        }
        if (copyToClipboard) {
          navigator.clipboard.writeText(text).catch(console.debug);
        }
        break;
      }
      default:
        break;
    }

    return undefined;
  });
}
