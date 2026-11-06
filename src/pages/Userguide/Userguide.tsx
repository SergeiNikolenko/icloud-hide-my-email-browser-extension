import React, { InputHTMLAttributes, ReactNode, useState } from 'react';
import { CircleCheck } from 'lucide-react';
import { Link } from '../../commonComponents';
import { isFirefox } from '../../browserUtils';

const Section = (props: { title: string; children: ReactNode }) => (
  <section className="space-y-2">
    <h2 className="lg-title px-3">{props.title}</h2>
    <div className="lg-group space-y-3 rounded-2xl px-4 py-3.5 [&>*+*]:border-t-0">
      {props.children}
    </div>
  </section>
);

const SignInInstructions = () => {
  return (
    <>
      <p>
        Sign in to your iCloud account on{' '}
        <Link href="https://www.icloud.com" className="font-medium">
          icloud.com
        </Link>{' '}
        in this browser, including{' '}
        <span className="font-medium">two-factor authentication</span> and{' '}
        <span className="font-medium">Trust This Browser</span>.
      </p>
      <img
        className="mx-auto rounded-[10px]"
        src="./icloud-sign-in.webp"
        alt="Screenshots of the icloud.com sign-in flow"
      />
      <p>
        Once signed in, open the extension pop-up to create a Hide My Email
        address. If you are already signed in, the extension is ready to use.
      </p>
      <p>
        Ticking <span className="font-medium">Keep me signed in</span> is
        optional, but it keeps the extension signed in as well, so you sign in
        less often.
      </p>
      {isFirefox && (
        <p>
          With Firefox Multi-Account Containers, sign in to icloud.com from a
          default tab outside any container. After that the extension works in
          every tab.
        </p>
      )}
    </>
  );
};

const AutofillableDemoInput = (props: {
  inputAttributes: InputHTMLAttributes<HTMLInputElement>;
  label: string;
}) => {
  const [value, setValue] = useState<string>();

  return (
    <label className="lg-row">
      <span className="flex-none">{props.label}</span>
      <input
        className="lg-field"
        onInput={(e) => setValue((e.target as HTMLInputElement).value)}
        {...props.inputAttributes}
      />
      {value?.endsWith('@icloud.com') && (
        <CircleCheck className="size-4 flex-none text-[var(--success)]" />
      )}
    </label>
  );
};

const UsageInstructions = () => {
  return (
    <>
      <p>
        The extension detects email fields and offers a new address right under
        them. You can also right-click any text field and choose the
        extension&apos;s menu item, or use the pop-up to create and manage
        addresses.
      </p>
      <form className="lg-inset">
        <AutofillableDemoInput
          label="Button"
          inputAttributes={{
            id: 'autofill-by-button',
            name: 'email',
            type: 'email',
            placeholder: 'Click this field',
          }}
        />
        <AutofillableDemoInput
          label="Context menu"
          inputAttributes={{
            id: 'autofill-by-right-click',
            type: 'text',
            placeholder: 'Right-click this field',
          }}
        />
      </form>
      <p>
        You can turn off the button in{' '}
        <Link href="./options.html">Settings</Link>. Addresses created here are
        real: deactivate and delete them in the pop-up under Addresses.
      </p>
    </>
  );
};

const TechnicalOverview = () => {
  return (
    <>
      <p>
        The extension talks to the iCloud APIs the same way the{' '}
        <Link href="https://www.icloud.com">icloud.com</Link> web app does. It
        has{' '}
        <Link href="https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/host_permissions">
          host permissions
        </Link>{' '}
        for icloud.com, so its requests carry the cookies your browser stored
        when you signed in.
      </p>
      <p>
        <span className="font-medium">
          The extension never sees your Apple Account email or password.
        </span>{' '}
        The{' '}
        <Link href="https://github.com/dedoussis/icloud-hide-my-email-browser-extension">
          source code
        </Link>{' '}
        is public.
      </p>
    </>
  );
};

const Userguide = () => {
  return (
    <main className="mx-auto max-w-[640px] space-y-6 px-5 pt-8 pb-20 [--row-height:36px]">
      <h1 className="lg-large-title px-3">Hide My Email</h1>
      <Section title="Sign In to iCloud">
        <SignInInstructions />
      </Section>
      <Section title="How to Use">
        <UsageInstructions />
      </Section>
      <Section title="How It Works">
        <TechnicalOverview />
      </Section>
    </main>
  );
};

export default Userguide;
