import React, { ButtonHTMLAttributes, DetailedHTMLProps } from 'react';
import { LoaderCircle } from 'lucide-react';

export const Spinner = (props: { className?: string }) => {
  return (
    <div
      className={`flex justify-center py-5 lg-secondary ${
        props.className ?? ''
      }`}
    >
      <LoaderCircle className="size-5 animate-spin" aria-label="Loading" />
    </div>
  );
};

export const LoadingButton = (
  props: {
    loading: boolean;
    variant?: 'primary' | 'secondary';
  } & DetailedHTMLProps<
    ButtonHTMLAttributes<HTMLButtonElement>,
    HTMLButtonElement
  >
) => {
  const {
    loading,
    disabled,
    variant = 'primary',
    className,
    children,
    ...btnHtmlAttrs
  } = props;

  return (
    <button
      type="submit"
      className={`lg-btn lg-btn-${variant} ${className ?? ''}`}
      disabled={loading || disabled}
      aria-busy={loading}
      {...btnHtmlAttrs}
    >
      {loading && <LoaderCircle className="animate-spin" />}
      {children}
    </button>
  );
};

export const ErrorMessage = (props: { children?: React.ReactNode }) => {
  return (
    <div className="lg-alert lg-enter" role="alert">
      {props.children}
    </div>
  );
};

export const Link = (
  props: React.DetailedHTMLProps<
    React.AnchorHTMLAttributes<HTMLAnchorElement>,
    HTMLAnchorElement
  >
) => {
  // https://github.com/jsx-eslint/eslint-plugin-react/issues/3284
  // eslint-disable-next-line react/prop-types
  const { className, children, ...restProps } = props;
  return (
    <a
      className={`lg-link ${className ?? ''}`}
      target="_blank"
      rel="noreferrer"
      {...restProps}
    >
      {children}
    </a>
  );
};
