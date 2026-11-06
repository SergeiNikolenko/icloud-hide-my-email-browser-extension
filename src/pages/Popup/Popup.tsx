import React, { useState, useEffect, useMemo, ReactNode } from 'react';
import ICloudClient, {
  PremiumMailSettings,
  HmeEmail,
} from '../../iCloudClient';
import { useBrowserStorageState } from '../../hooks';
import {
  RefreshCw,
  Copy,
  Check,
  TextCursorInput,
  LogOut,
  Settings,
  Search,
  ChevronRight,
  ChevronLeft,
  CircleHelp,
  ExternalLink,
  LucideIcon,
} from 'lucide-react';
import { MessageType, sendMessageToTab } from '../../messages';
import {
  ErrorMessage,
  LoadingButton,
  Spinner,
  Link,
} from '../../commonComponents';
import { errorToString } from '../../errors';
import browser from 'webextension-polyfill';
import Fuse from 'fuse.js';
import {
  PopupAction,
  PopupState,
  STATE_MACHINE_TRANSITIONS,
} from './stateMachine';
import {
  CONTEXT_MENU_ITEM_ID,
  SIGNED_OUT_CTA_COPY,
} from '../Background/constants';
import { isFirefox } from '../../browserUtils';

const COPIED_FEEDBACK_MS = 1500;

const useCopyToClipboard = (): [boolean, (text: string) => Promise<void>] => {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) {
      return;
    }
    const timeout = setTimeout(() => setCopied(false), COPIED_FEEDBACK_MS);
    return () => clearTimeout(timeout);
  }, [copied]);

  const copy = async (text: string) => {
    await navigator.clipboard.writeText(text);
    setCopied(true);
  };

  return [copied, copy];
};

const IconButton = (props: {
  icon: LucideIcon;
  label: string;
  onClick: () => void;
  spin?: boolean;
  disabled?: boolean;
}) => {
  const { icon: Icon, label, onClick, spin, disabled } = props;
  return (
    <button
      type="button"
      className="lg-icon-btn"
      title={label}
      aria-label={label}
      onClick={onClick}
      disabled={disabled}
    >
      <Icon className={`size-4 ${spin ? 'animate-spin' : ''}`} />
    </button>
  );
};

const AddressActions = (props: { hme: string }) => {
  const [copied, copy] = useCopyToClipboard();

  return (
    <div className="grid grid-cols-2 gap-2" aria-live="polite">
      <button
        type="button"
        className="lg-btn lg-btn-secondary"
        onClick={() => copy(props.hme)}
      >
        {copied ? <Check /> : <Copy />}
        {copied ? 'Copied' : 'Copy'}
      </button>
      <button
        type="button"
        className="lg-btn lg-btn-secondary"
        onClick={() => sendMessageToTab(MessageType.Autofill, props.hme)}
      >
        <TextCursorInput />
        Autofill
      </button>
    </div>
  );
};

const SignInInstructions = () => {
  const userguideUrl = browser.runtime.getURL('userguide.html');

  return (
    <div className="space-y-3 lg-enter">
      <div className="lg-group">
        <p className="px-3 py-2.5">
          Sign in on{' '}
          <Link href="https://www.icloud.com" className="font-medium">
            icloud.com
          </Link>{' '}
          in this browser.
        </p>
        <p className="px-3 py-2.5">
          Complete two-factor authentication and choose{' '}
          <span className="font-medium">Trust</span> for this browser.
        </p>
        <p className="px-3 py-2.5">
          Tick <span className="font-medium">Keep me signed in</span> to stay
          signed in here too.
        </p>
        {isFirefox && (
          <p className="px-3 py-2.5">
            Sign in from a tab outside{' '}
            <Link href="https://support.mozilla.org/kb/containers">
              Firefox Containers
            </Link>
            .
          </p>
        )}
      </div>
      <div className="grid grid-cols-2 gap-2">
        <a
          href={userguideUrl}
          target="_blank"
          rel="noreferrer"
          className="lg-btn lg-btn-secondary"
        >
          <CircleHelp />
          Help
        </a>
        <a
          href="https://www.icloud.com"
          target="_blank"
          rel="noreferrer"
          className="lg-btn lg-btn-primary"
        >
          <ExternalLink />
          iCloud.com
        </a>
      </div>
    </div>
  );
};

const HmeGenerator = (props: { client: ICloudClient }) => {
  const [hmeEmail, setHmeEmail] = useState<string>();
  const [hmeError, setHmeError] = useState<string>();
  const [fwdToEmail, setFwdToEmail] = useState<string>();

  const [reservedHme, setReservedHme] = useState<HmeEmail>();
  const [reserveError, setReserveError] = useState<string>();

  const [isGenerating, setIsGenerating] = useState(true);
  const [isReserving, setIsReserving] = useState(false);
  const [tabHost, setTabHost] = useState('');
  const [label, setLabel] = useState('');
  const [note, setNote] = useState('');

  const generate = async () => {
    setIsGenerating(true);
    setReservedHme(undefined);
    setHmeError(undefined);
    setReserveError(undefined);
    try {
      const pms = new PremiumMailSettings(props.client);
      setHmeEmail(await pms.generateHme());
    } catch (e) {
      setHmeError(errorToString(e));
    } finally {
      setIsGenerating(false);
    }
  };

  useEffect(() => {
    const pms = new PremiumMailSettings(props.client);
    pms
      .listHme()
      .then((result) => setFwdToEmail(result.selectedForwardTo))
      .catch(console.debug);
    generate();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.client]);

  useEffect(() => {
    const getTabHost = async () => {
      const [tab] = await browser.tabs.query({
        active: true,
        lastFocusedWindow: true,
      });
      if (tab?.url === undefined) {
        return;
      }
      const { protocol, hostname } = new URL(tab.url);
      if (protocol === 'http:' || protocol === 'https:') {
        setTabHost(hostname);
        setLabel(hostname);
      }
    };

    getTabHost().catch(console.error);
  }, []);

  const onReserveSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (hmeEmail === undefined) {
      return;
    }
    setIsReserving(true);
    setReserveError(undefined);
    try {
      const pms = new PremiumMailSettings(props.client);
      setReservedHme(
        await pms.reserveHme(
          hmeEmail,
          label.trim() || tabHost,
          note.trim() || undefined
        )
      );
    } catch (e) {
      setReserveError(errorToString(e));
    } finally {
      setIsReserving(false);
    }
  };

  const isReserved = reservedHme !== undefined && reservedHme.hme === hmeEmail;

  return (
    <div className="space-y-3 lg-enter">
      <section
        className="lg-card relative px-4 pt-5 pb-4 text-center"
        aria-live="polite"
      >
        <div className="absolute top-1.5 right-1.5">
          <IconButton
            icon={RefreshCw}
            label="New address"
            onClick={generate}
            spin={isGenerating}
            disabled={isGenerating || isReserving}
          />
        </div>
        <p
          translate="no"
          className={`min-h-[22px] px-7 text-[17px] leading-[22px] font-semibold break-all select-all transition-opacity ${
            isGenerating ? 'opacity-40' : ''
          }`}
        >
          {hmeEmail ?? ' '}
        </p>
        {fwdToEmail && (
          <p className="mt-1 text-[12px] leading-4 lg-secondary truncate">
            Forwards to {fwdToEmail}
          </p>
        )}
        {isReserved && (
          <p className="mt-2 inline-flex items-center gap-1 font-semibold text-[var(--success)] lg-enter">
            <Check className="size-3.5" />
            Reserved
          </p>
        )}
      </section>
      {hmeError && <ErrorMessage>{hmeError}</ErrorMessage>}
      {hmeEmail && !isReserved && (
        <form className="space-y-3" onSubmit={onReserveSubmit}>
          <div className="lg-group">
            <label className="lg-row">
              <span>Label</span>
              <input
                className="lg-field"
                autoComplete="off"
                spellCheck={false}
                placeholder={tabHost || 'Required'}
                required={!tabHost}
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                disabled={isGenerating || isReserving}
              />
            </label>
            <label className="lg-row">
              <span>Note</span>
              <input
                className="lg-field"
                autoComplete="off"
                placeholder="Optional"
                value={note}
                onChange={(e) => setNote(e.target.value)}
                disabled={isGenerating || isReserving}
              />
            </label>
          </div>
          <LoadingButton
            className="w-full"
            loading={isReserving}
            disabled={isGenerating}
          >
            Use This Address
          </LoadingButton>
          {reserveError && <ErrorMessage>{reserveError}</ErrorMessage>}
        </form>
      )}
      {isReserved && <AddressActions hme={reservedHme.hme} />}
    </div>
  );
};

const EditableRow = (props: {
  label: string;
  value: string;
  placeholder: string;
  onCommit: (value: string) => void;
  disabled: boolean;
}) => {
  const [draft, setDraft] = useState(props.value);

  useEffect(() => setDraft(props.value), [props.value]);

  const commit = () => {
    if (draft.trim() !== props.value) {
      props.onCommit(draft.trim());
    }
  };

  return (
    <label className="lg-row">
      <span>{props.label}</span>
      <input
        className="lg-field"
        autoComplete="off"
        value={draft}
        placeholder={props.placeholder}
        disabled={props.disabled}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.currentTarget.blur();
          } else if (e.key === 'Escape') {
            setDraft(props.value);
          }
        }}
      />
    </label>
  );
};

const HmeDetails = (props: {
  hme: HmeEmail;
  client: ICloudClient;
  onBack: () => void;
  onChange: (hme: HmeEmail) => void;
  onDelete: () => void;
}) => {
  const { hme, client } = props;
  const [pendingAction, setPendingAction] = useState<
    'activation' | 'delete' | 'metadata'
  >();
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [error, setError] = useState<string>();

  const run = async (
    action: NonNullable<typeof pendingAction>,
    fn: (pms: PremiumMailSettings) => Promise<void>
  ) => {
    setPendingAction(action);
    setError(undefined);
    try {
      await fn(new PremiumMailSettings(client));
    } catch (e) {
      setError(errorToString(e));
    } finally {
      setPendingAction(undefined);
    }
  };

  const onActivationClick = () =>
    run('activation', async (pms) => {
      if (hme.isActive) {
        await pms.deactivateHme(hme.anonymousId);
      } else {
        await pms.reactivateHme(hme.anonymousId);
      }
      props.onChange({ ...hme, isActive: !hme.isActive });
    });

  const onDeleteClick = () => {
    if (!confirmDelete) {
      setConfirmDelete(true);
      return;
    }
    run('delete', async (pms) => {
      await pms.deleteHme(hme.anonymousId);
      props.onDelete();
    });
  };

  const onMetadataCommit = (patch: Partial<Pick<HmeEmail, 'label' | 'note'>>) =>
    run('metadata', async (pms) => {
      const next = { ...hme, ...patch };
      await pms.updateHmeMetadata(
        hme.anonymousId,
        next.label,
        next.note || undefined
      );
      props.onChange(next);
    });

  const isBusy = pendingAction !== undefined;

  return (
    <div className="space-y-3 lg-enter">
      <button type="button" className="lg-back" onClick={props.onBack}>
        <ChevronLeft className="size-[18px]" />
        Addresses
      </button>
      <section className="lg-card px-4 py-4 text-center">
        <p
          translate="no"
          className="text-[15px] leading-5 font-semibold break-all select-all"
        >
          {hme.hme}
        </p>
        <p className="mt-1 text-[12px] leading-4 lg-secondary truncate">
          Forwards to {hme.forwardToEmail}
        </p>
        {!hme.isActive && (
          <p className="mt-1.5 font-semibold text-[var(--destructive)]">
            Inactive
          </p>
        )}
      </section>
      {hme.isActive && <AddressActions hme={hme.hme} />}
      <div className="lg-group">
        <EditableRow
          label="Label"
          value={hme.label}
          placeholder="Required"
          disabled={isBusy}
          onCommit={(label) => label && onMetadataCommit({ label })}
        />
        <EditableRow
          label="Note"
          value={hme.note ?? ''}
          placeholder="Optional"
          disabled={isBusy}
          onCommit={(note) => onMetadataCommit({ note })}
        />
        <div className="lg-row">
          <span>Created</span>
          <span className="ml-auto lg-secondary">
            {new Date(hme.createTimestamp).toLocaleDateString(undefined, {
              dateStyle: 'medium',
            })}
          </span>
        </div>
      </div>
      <div className="lg-group">
        <button
          type="button"
          className={`lg-row ${
            hme.isActive ? 'text-[var(--destructive)]' : ''
          }`}
          onClick={onActivationClick}
          disabled={isBusy}
        >
          {hme.isActive ? 'Deactivate Address' : 'Reactivate Address'}
          {pendingAction === 'activation' && (
            <RefreshCw className="ml-auto size-3.5 animate-spin lg-secondary" />
          )}
        </button>
        {!hme.isActive && (
          <button
            type="button"
            className="lg-row text-[var(--destructive)]"
            onClick={onDeleteClick}
            onBlur={() => setConfirmDelete(false)}
            disabled={isBusy}
          >
            {confirmDelete ? 'Confirm Delete' : 'Delete Address'}
            {pendingAction === 'delete' && (
              <RefreshCw className="ml-auto size-3.5 animate-spin lg-secondary" />
            )}
          </button>
        )}
      </div>
      {error && <ErrorMessage>{error}</ErrorMessage>}
    </div>
  );
};

const HmeManager = (props: { client: ICloudClient }) => {
  const [hmeEmails, setHmeEmails] = useState<HmeEmail[]>();
  const [error, setError] = useState<string>();
  const [searchPrompt, setSearchPrompt] = useState('');
  const [selectedId, setSelectedId] = useState<string>();

  useEffect(() => {
    const fetchHmeList = async () => {
      setError(undefined);
      try {
        const pms = new PremiumMailSettings(props.client);
        const result = await pms.listHme();
        setHmeEmails(
          [...result.hmeEmails].sort(
            (a, b) => b.createTimestamp - a.createTimestamp
          )
        );
      } catch (e) {
        setError(errorToString(e));
      }
    };

    fetchHmeList();
  }, [props.client]);

  const searchEngine = useMemo(
    () =>
      new Fuse(hmeEmails ?? [], {
        keys: ['label', 'hme', 'note'],
        threshold: 0.4,
      }),
    [hmeEmails]
  );

  if (error) {
    return <ErrorMessage>{error}</ErrorMessage>;
  }

  if (hmeEmails === undefined) {
    return <Spinner />;
  }

  const selectedHme = hmeEmails.find((h) => h.anonymousId === selectedId);
  if (selectedHme) {
    return (
      <HmeDetails
        key={selectedHme.anonymousId}
        hme={selectedHme}
        client={props.client}
        onBack={() => setSelectedId(undefined)}
        onChange={(next) =>
          setHmeEmails((prev) =>
            prev?.map((h) => (h.anonymousId === next.anonymousId ? next : h))
          )
        }
        onDelete={() => {
          setHmeEmails((prev) =>
            prev?.filter((h) => h.anonymousId !== selectedHme.anonymousId)
          );
          setSelectedId(undefined);
        }}
      />
    );
  }

  const visibleHmeEmails = searchPrompt
    ? searchEngine.search(searchPrompt).map((result) => result.item)
    : hmeEmails;

  let list: ReactNode;
  if (hmeEmails.length === 0) {
    list = <p className="py-8 text-center lg-secondary">No addresses</p>;
  } else if (visibleHmeEmails.length === 0) {
    list = (
      <p className="py-8 text-center lg-secondary break-words">No results</p>
    );
  } else {
    list = (
      <div className="lg-group">
        {visibleHmeEmails.map((hme) => (
          <button
            key={hme.anonymousId}
            type="button"
            className="lg-row py-1.5"
            onClick={() => setSelectedId(hme.anonymousId)}
          >
            <span className="min-w-0 flex-1">
              <span className="block truncate font-medium">{hme.label}</span>
              <span
                translate="no"
                className="block truncate text-[12px] leading-4 lg-secondary"
              >
                {hme.hme}
              </span>
            </span>
            {!hme.isActive && (
              <span className="text-[12px] font-medium text-[var(--destructive)]">
                Inactive
              </span>
            )}
            <ChevronRight className="size-3.5 flex-none text-[var(--tertiary-label)]" />
          </button>
        ))}
      </div>
    );
  }

  return (
    <div className="space-y-3 lg-enter">
      {hmeEmails.length > 0 && (
        <label className="lg-search">
          <Search className="size-3.5 flex-none" />
          <input
            type="search"
            placeholder="Search…"
            aria-label="Search addresses"
            autoComplete="off"
            spellCheck={false}
            value={searchPrompt}
            // eslint-disable-next-line jsx-a11y/no-autofocus
            autoFocus
            onChange={(e) => setSearchPrompt(e.target.value)}
          />
        </label>
      )}
      {list}
    </div>
  );
};

const SegmentedControl = <T extends string>(props: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (value: T) => void;
}) => {
  const selectedIdx = props.options.findIndex((o) => o.value === props.value);

  return (
    <div className="lg-segmented" role="tablist">
      <div
        className="lg-segmented-thumb"
        style={{
          width: `calc((100% - 4px) / ${props.options.length})`,
          transform: `translateX(${selectedIdx * 100}%)`,
        }}
      />
      {props.options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="tab"
          className="lg-segment"
          aria-selected={option.value === props.value}
          onClick={() => props.onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
};

async function performDeauthSideEffects(): Promise<void> {
  await browser.contextMenus
    .update(CONTEXT_MENU_ITEM_ID, {
      title: SIGNED_OUT_CTA_COPY,
      enabled: false,
    })
    .catch(console.debug);
}

const Popup = () => {
  const [state, setState, isStateLoading] = useBrowserStorageState(
    'popupState',
    PopupState.SignedOut
  );

  const [clientState, setClientState, isClientStateLoading] =
    useBrowserStorageState('clientState', undefined);
  const [clientAuthStateSynced, setClientAuthStateSynced] = useState(false);

  useEffect(() => {
    const syncClientAuthState = async () => {
      const syncClient =
        clientState &&
        new ICloudClient(clientState.setupUrl, clientState.webservices);
      const isAuthenticated =
        syncClient !== undefined && (await syncClient.isAuthenticated());

      if (isAuthenticated) {
        // Validation may return refreshed service URLs; keep them.
        setClientState({
          setupUrl: syncClient.setupUrl,
          webservices: syncClient.webservices,
        });
        setState((prevState) =>
          prevState === PopupState.SignedOut
            ? PopupState.Authenticated
            : prevState
        );
      } else {
        setState(PopupState.SignedOut);
        setClientState(undefined);
        performDeauthSideEffects();
      }

      setClientAuthStateSynced(true);
    };

    if (!isStateLoading && !isClientStateLoading && !clientAuthStateSynced) {
      syncClientAuthState();
    }
  }, [
    setState,
    setClientState,
    clientAuthStateSynced,
    clientState,
    isStateLoading,
    isClientStateLoading,
  ]);

  // A stable client instance keeps the views from refetching on every render.
  const client = useMemo(
    () =>
      clientState &&
      new ICloudClient(clientState.setupUrl, clientState.webservices),
    [clientState]
  );

  const transition = (action: PopupAction) => {
    const transitions = STATE_MACHINE_TRANSITIONS[state] as Partial<
      Record<PopupAction, PopupState>
    >;
    const nextState = transitions[action];
    if (nextState !== undefined) {
      setState(nextState);
    }
  };

  const signOut = async () => {
    await client?.signOut();
    setClientState(undefined);
    performDeauthSideEffects();
    transition('SIGN_OUT');
  };

  const isLoading = isStateLoading || !clientAuthStateSynced;
  const isSignedIn =
    !isLoading && state !== PopupState.SignedOut && client !== undefined;

  let content: ReactNode;
  if (isLoading) {
    content = <Spinner />;
  } else if (!isSignedIn) {
    content = <SignInInstructions />;
  } else if (state === PopupState.AuthenticatedAndManaging) {
    content = <HmeManager client={client} />;
  } else {
    content = <HmeGenerator client={client} />;
  }

  return (
    <div>
      <header className="lg-toolbar space-y-2 px-3 pt-2.5 pb-2.5">
        <div className="flex h-7 items-center justify-between">
          <h1 className="lg-title pl-1">Hide My Email</h1>
          {isSignedIn && (
            <div className="-mr-1 flex">
              <IconButton
                icon={Settings}
                label="Settings"
                onClick={() => browser.runtime.openOptionsPage()}
              />
              <IconButton icon={LogOut} label="Sign out" onClick={signOut} />
            </div>
          )}
        </div>
        {isSignedIn && (
          <SegmentedControl
            value={
              state === PopupState.AuthenticatedAndManaging
                ? 'MANAGE'
                : 'GENERATE'
            }
            options={[
              { value: 'GENERATE', label: 'New Address' },
              { value: 'MANAGE', label: 'Addresses' },
            ]}
            onChange={(action) => transition(action)}
          />
        )}
      </header>
      <main className="px-3 pt-1 pb-3">{content}</main>
    </div>
  );
};

export default Popup;
