'use client';

import { Search, X } from 'lucide-react';
import { useCallback, useState, useEffect, useMemo } from 'react';
import { cn } from '@/src/lib/utils';
import debounce from 'lodash/debounce';
import Fuse from 'fuse.js';
import type { Plugin } from '../types';
import { CompactPluginCard } from '../plugin-card/compact';

interface SearchBarProps {
  className?: string;
  allApps: Plugin[];
  onSearching?: (searching: boolean) => void;
}

export function SearchBar({ className, allApps, onSearching }: SearchBarProps) {
  const [searchQuery, setSearchQuery] = useState('');
  const [isFocused, setIsFocused] = useState(false);
  const [searchResults, setSearchResults] = useState<Plugin[]>([]);
  const [fuse, setFuse] = useState<Fuse<Plugin> | null>(null);
  const [isSearching, setIsSearching] = useState(false);

  // Initialize Fuse.js instance
  useEffect(() => {
    const fuseInstance = new Fuse(allApps, {
      keys: ['name', 'description', 'author', 'category', 'capabilities'],
      threshold: 0.3,
      includeMatches: true,
    });
    setFuse(fuseInstance);
  }, [allApps]);

  const handleSearch = useCallback(
    (query: string) => {
      setSearchQuery(query);
      const searchContent = query.toLowerCase().trim();

      if (!searchContent || !fuse) {
        setIsSearching(false);
        setSearchResults([]);
        onSearching?.(false);
        return;
      }

      // Get search results
      const results = fuse.search(searchContent);
      setSearchResults(results.map((result) => result.item));
      setIsSearching(true);
      onSearching?.(true);
    },
    [fuse, onSearching],
  );

  const debouncedSearch = useMemo(
    () => debounce((query: string) => handleSearch(query), 150),
    [handleSearch],
  );

  const clearSearch = useCallback(() => {
    setSearchQuery('');
    handleSearch('');
  }, [handleSearch]);

  useEffect(() => {
    return () => {
      debouncedSearch.cancel();
    };
  }, [debouncedSearch]);

  return (
    <div className="w-full">
      <div className={cn('relative mx-auto w-full max-w-2xl', className)}>
        <div className="group relative">
          <Search
            className={cn(
              'absolute left-4 top-1/2 h-4 w-4 -translate-y-1/2 transition-colors',
              isFocused || searchQuery
                ? 'text-[var(--market-accent)]'
                : 'text-[var(--market-muted)] group-hover:text-[var(--market-accent)]',
            )}
          />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => {
              setSearchQuery(e.target.value);
              debouncedSearch(e.target.value);
            }}
            onFocus={() => setIsFocused(true)}
            onBlur={() => setIsFocused(false)}
            placeholder="Search apps, categories, or capabilities..."
            className="h-12 w-full rounded-2xl border border-[rgba(248,244,234,0.08)] bg-[rgba(27,25,20,0.8)] pl-11 pr-11 text-sm text-[var(--market-ink)] placeholder-[var(--market-muted)] outline-none ring-0 transition-all hover:border-[rgba(248,244,234,0.16)] focus:border-[rgba(213,168,79,0.42)] focus:bg-[#211f19]"
          />
          {searchQuery && (
            <button
              onClick={clearSearch}
              className="absolute right-4 top-1/2 -translate-y-1/2 text-[var(--market-muted)] transition-colors hover:text-[var(--market-ink)]"
            >
              <X className="h-4 w-4" />
            </button>
          )}
        </div>
      </div>

      {/* Search Results */}
      {isSearching && (
        <div className="container mx-auto mt-8">
          <div className="space-y-4">
            <h2 className="text-xl font-semibold tracking-[-0.025em] text-[var(--market-ink)]">
              Search Results ({searchResults.length})
            </h2>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {searchResults.map((plugin, index) => (
                <CompactPluginCard key={plugin.id} plugin={plugin} index={index + 1} />
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
