'use client';

import { Star, Download } from 'lucide-react';
import Image from 'next/image';
import Link from 'next/link';
import type { Plugin, PluginStat } from '../types';
import { NewBadge } from '../new-badge';

export interface CompactPluginCardProps {
  plugin: Plugin;
  stat?: PluginStat;
  index: number;
}

const formatInstalls = (num: number) => {
  if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
  if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
  return num.toString();
};

export function CompactPluginCard({ plugin, index }: CompactPluginCardProps) {
  return (
    <Link
      href={`/apps/${plugin.id}`}
      className="market-card-hover group flex items-start gap-3 rounded-[1.25rem] border border-transparent p-2.5 text-left hover:bg-[rgba(255,248,231,0.045)]"
      data-plugin-card
      data-plugin-id={plugin.id}
      data-search-content={`${plugin.name} ${plugin.author} ${plugin.description}`}
      data-categories={plugin.category}
      data-capabilities={Array.from(plugin.capabilities).join(' ')}
    >
      {/* Index number */}
      <span className="flex w-5 shrink-0 items-center font-mono text-xs font-semibold tabular-nums text-[var(--market-accent-soft)]">
        {index}
      </span>

      {/* App icon */}
      <Image
        src={plugin.image || 'https://via.placeholder.com/40'}
        alt={plugin.name}
        className="h-11 w-11 shrink-0 rounded-[1rem] object-cover saturate-[0.86] sm:h-14 sm:w-14"
        width={56}
        height={56}
      />

      {/* Content */}
      <div className="min-w-0 flex-1 space-y-0.5">
        {/* Title and NEW badge */}
        <div className="flex items-center gap-2">
          <h3 className="flex-1 truncate font-semibold tracking-[-0.02em] text-[var(--market-ink)] transition-colors group-hover:text-[var(--market-accent-soft)]">
            {plugin.name}
          </h3>
          <NewBadge plugin={plugin} />
        </div>

        {/* Author and Stats Row */}
        <div className="flex items-center justify-between gap-2">
          <span className="truncate text-xs text-[var(--market-muted)]">
            by {plugin.author}
          </span>
          <div className="flex shrink-0 items-center gap-2.5 font-mono text-[0.68rem] text-[var(--market-muted)]">
            <div className="flex items-center">
              <Star className="mr-1 h-3.5 w-3.5" />
              <span>{plugin.rating_avg?.toFixed(1)}</span>
            </div>
            <div className="flex items-center">
              <Download className="mr-1 h-3 w-3" />
              <span>{formatInstalls(plugin.installs)}</span>
            </div>
          </div>
        </div>

        {/* Description */}
        <p className="line-clamp-1 text-xs text-[var(--market-muted)] transition-colors group-hover:text-[#d8d0c1] sm:text-sm">
          {plugin.description}
        </p>
      </div>
    </Link>
  );
}
