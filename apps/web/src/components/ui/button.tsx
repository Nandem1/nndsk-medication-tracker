import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "../../lib/utils";
import type { ComponentProps } from "react";
const variants = cva(
  "inline-flex min-h-11 items-center justify-center rounded-lg px-4 py-2 text-base font-semibold focus-visible:outline-3 focus-visible:outline-offset-2 focus-visible:outline-(--mt-color-accent) disabled:opacity-50 disabled:cursor-not-allowed",
  {
    variants: {
      variant: {
        default:
          "bg-(--mt-color-action) text-(--mt-color-on-action) hover:opacity-90",
        outline:
          "border border-(--mt-color-border-strong) bg-(--mt-color-surface) text-(--mt-color-text) hover:bg-(--mt-color-surface-raised)",
        destructive:
          "border border-(--mt-color-danger-fg) bg-(--mt-color-danger-bg) text-(--mt-color-danger-fg) hover:opacity-90",
      },
    },
    defaultVariants: { variant: "default" },
  },
);
export function Button({
  className,
  variant,
  asChild = false,
  ...props
}: ComponentProps<"button"> &
  VariantProps<typeof variants> & { asChild?: boolean }) {
  const Component = asChild ? Slot : "button";
  return (
    <Component className={cn(variants({ variant }), className)} {...props} />
  );
}
