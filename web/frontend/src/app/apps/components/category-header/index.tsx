'use client';

import { getCategoryMetadata } from '../../utils/category';

interface CategoryHeaderProps {
  category: string;
  totalApps: number;
}

export function CategoryHeader({ category, totalApps }: CategoryHeaderProps) {
  const metadata = getCategoryMetadata(category);
  const Icon = metadata.icon;

  return (
    <div className="flex items-center gap-2 sm:gap-4">
      <div className="rounded-xl border border-[rgba(248,244,234,0.08)] bg-[rgba(213,168,79,0.12)] p-2 text-[var(--market-accent-soft)] sm:rounded-2xl sm:p-3">
        <Icon className="h-5 w-5 sm:h-8 sm:w-8" />
      </div>
      <div className="min-w-0 flex-1">
        <h1 className="flex items-center gap-2 text-xl font-bold tracking-[-0.035em] text-[var(--market-ink)] sm:text-2xl md:text-3xl">
          {metadata.displayName}
          <span className="inline-flex items-center rounded-xl bg-white/5 px-2 py-0.5 font-mono text-sm tabular-nums text-[var(--market-muted)] sm:text-base">
            {totalApps}
          </span>
        </h1>
        <p className="mt-0.5 line-clamp-1 text-sm leading-6 text-[var(--market-muted)] sm:mt-2 sm:line-clamp-none sm:text-base">
          {metadata.description}
        </p>
      </div>
    </div>
  );
}
