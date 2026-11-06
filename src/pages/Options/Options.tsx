import React, { useState, useEffect, ReactNode } from 'react';
import { ArrowUpRight, Check, LoaderCircle } from 'lucide-react';
import { useBrowserStorageState } from '../../hooks';
import ICloudClient, { PremiumMailSettings } from '../../iCloudClient';
import { Spinner, ErrorMessage, Link } from '../../commonComponents';
import { errorToString } from '../../errors';
import { Autofill, DEFAULT_STORE } from '../../storage';

const SELECT_FWD_TO_SIGNED_OUT_CTA_COPY =
  'Sign in from the extension pop-up to choose where addresses forward to.';

const AUTOFILL_LABELS: Record<keyof Autofill, string> = {
  button: 'Button Under Email Fields',
  contextMenu: 'Context Menu Item',
};

const Section = (props: { title: string; children: ReactNode }) => (
  <section className="space-y-1.5">
    <h2 className="lg-headline px-3">{props.title}</h2>
    {props.children}
  </section>
);

const SelectFwdToForm = () => {
  const [selectedFwdToEmail, setSelectedFwdToEmail] = useState<string>();
  const [fwdToEmails, setFwdToEmails] = useState<string[]>();
  const [pendingFwdToEmail, setPendingFwdToEmail] = useState<string>();
  const [listHmeError, setListHmeError] = useState<string>();
  const [updateFwdToError, setUpdateFwdToError] = useState<string>();
  const [client, setClient] = useState<ICloudClient>();
  const [clientState, , isClientStateLoading] = useBrowserStorageState(
    'clientState',
    undefined
  );

  useEffect(() => {
    const fetchHmeList = async () => {
      setListHmeError(undefined);

      const nextClient =
        clientState &&
        new ICloudClient(clientState.setupUrl, clientState.webservices);
      if (!nextClient || !(await nextClient.isAuthenticated())) {
        setListHmeError(SELECT_FWD_TO_SIGNED_OUT_CTA_COPY);
        return;
      }

      try {
        const result = await new PremiumMailSettings(nextClient).listHme();
        setFwdToEmails(result.forwardToEmails);
        setSelectedFwdToEmail(result.selectedForwardTo);
        setClient(nextClient);
      } catch (e) {
        setListHmeError(errorToString(e));
      }
    };

    if (!isClientStateLoading) {
      fetchHmeList();
    }
  }, [clientState, isClientStateLoading]);

  const onSelect = async (fwdToEmail: string) => {
    if (!client || fwdToEmail === selectedFwdToEmail) {
      return;
    }
    setPendingFwdToEmail(fwdToEmail);
    setUpdateFwdToError(undefined);
    try {
      await new PremiumMailSettings(client).updateForwardToHme(fwdToEmail);
      setSelectedFwdToEmail(fwdToEmail);
    } catch (e) {
      setUpdateFwdToError(errorToString(e));
    } finally {
      setPendingFwdToEmail(undefined);
    }
  };

  if (listHmeError !== undefined) {
    return <ErrorMessage>{listHmeError}</ErrorMessage>;
  }

  if (fwdToEmails === undefined) {
    return (
      <div className="lg-group">
        <Spinner />
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <div className="lg-group" role="radiogroup" aria-label="Forward To">
        {fwdToEmails.map((fwdToEmail) => {
          const isSelected = fwdToEmail === selectedFwdToEmail;
          return (
            <button
              key={fwdToEmail}
              type="button"
              role="radio"
              aria-checked={isSelected}
              className="lg-row"
              disabled={pendingFwdToEmail !== undefined}
              onClick={() => onSelect(fwdToEmail)}
            >
              <span className="flex-1 truncate">{fwdToEmail}</span>
              {pendingFwdToEmail === fwdToEmail ? (
                <LoaderCircle className="size-4 animate-spin lg-secondary" />
              ) : (
                isSelected && <Check className="size-4 text-[var(--tint)]" />
              )}
            </button>
          );
        })}
      </div>
      {updateFwdToError && <ErrorMessage>{updateFwdToError}</ErrorMessage>}
    </div>
  );
};

const AutofillForm = () => {
  const [options, setOptions] = useBrowserStorageState(
    'iCloudHmeOptions',
    DEFAULT_STORE.iCloudHmeOptions
  );
  const autofill = {
    ...DEFAULT_STORE.iCloudHmeOptions.autofill,
    ...options.autofill,
  };

  return (
    <div className="lg-group">
      {(Object.keys(AUTOFILL_LABELS) as (keyof Autofill)[]).map((key) => (
        <label key={key} className="lg-row cursor-pointer">
          <span className="flex-1">{AUTOFILL_LABELS[key]}</span>
          <input
            type="checkbox"
            role="switch"
            className="lg-switch"
            checked={autofill[key]}
            onChange={() =>
              setOptions({
                ...options,
                autofill: { ...autofill, [key]: !autofill[key] },
              })
            }
          />
        </label>
      ))}
    </div>
  );
};

const About = () => {
  return (
    <div className="lg-group">
      <p className="px-3 py-2.5">
        Not endorsed by, affiliated with, maintained, authorized, or sponsored
        by Apple. Developed independently by{' '}
        <Link href="https://twitter.com/dedoussis">Dimitrios Dedoussis</Link>{' '}
        and released under the MIT license.
      </p>
      <a
        className="lg-row group"
        href="https://github.com/dedoussis/icloud-hide-my-email-browser-extension"
        target="_blank"
        rel="noreferrer"
      >
        <span className="flex-1">Source Code</span>
        <ArrowUpRight className="size-3.5 text-[var(--tertiary-label)] group-hover:text-[var(--secondary-label)]" />
      </a>
      <a
        className="lg-row group"
        href="./userguide.html"
        target="_blank"
        rel="noreferrer"
      >
        <span className="flex-1">Quickstart Guide</span>
        <ArrowUpRight className="size-3.5 text-[var(--tertiary-label)] group-hover:text-[var(--secondary-label)]" />
      </a>
    </div>
  );
};

const Options = () => {
  return (
    <main className="mx-auto max-w-[540px] space-y-6 px-5 py-8 [--row-height:36px]">
      <h1 className="lg-large-title px-3">Settings</h1>
      <Section title="Forward To">
        <SelectFwdToForm />
      </Section>
      <Section title="Autofill">
        <AutofillForm />
      </Section>
      <Section title="About">
        <About />
      </Section>
    </main>
  );
};

export default Options;
