'use client';

import { FeaturedPluginCard } from './plugin-card/featured';
import { CompactPluginCard } from './plugin-card/compact';
import { CategoryHeader } from './category-header';
import type { Plugin, PluginStat } from './types';
import { ChevronRight, ChevronUp, Sparkles, Trophy } from 'lucide-react';
import { ScrollableCategoryNav } from './scrollable-category-nav';
import { SearchBar } from './search/search-bar';
import { useState, useMemo, useEffect, useRef } from 'react';
import { DeveloperBanner } from './developer-banner';

interface AppListProps {
  initialPlugins: Plugin[];
  initialStats: PluginStat[];
}

// Stable shuffle function using a seed
function seededShuffle<T>(array: T[], seed: number): T[] {
  const shuffled = [...array];
  const random = (i: number) => {
    const x = Math.sin(i + seed) * 10000;
    return x - Math.floor(x);
  };

  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(random(i) * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
  }
  return shuffled;
}

export default function AppList({ initialPlugins, initialStats }: AppListProps) {
  const [isSearching, setIsSearching] = useState(false);
  const [headerMinimized, setHeaderMinimized] = useState(false);
  const headerRef = useRef<HTMLDivElement>(null);
  const heroRef = useRef<HTMLDivElement>(null);

  // Handle scroll behavior for header
  useEffect(() => {
    const handleScroll = () => {
      if (window.scrollY > 100) {
        setHeaderMinimized(true);
      } else {
        setHeaderMinimized(false);
      }
    };

    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll);
  }, []);

  // Use useMemo to ensure consistent results between renders
  const { featuredApps, mostPopular, integrationApps, sortedCategories } = useMemo(() => {
    // Get featured plugins (with at least 100 installs) and randomize the selection
    const featured = seededShuffle(
      initialPlugins.filter((plugin) => plugin.installs >= 100),
      2, // Using a different seed for consistent but random results
    ).slice(0, 3);

    // Sort plugins by different criteria
    const mostPopular = [...initialPlugins]
      .sort((a, b) => b.installs - a.installs)
      .slice(0, 9);

    // Get integration apps
    const integrationApps = [...initialPlugins]
      .filter((plugin) => plugin.capabilities.has('external_integration'))
      .sort((a, b) => b.installs - a.installs)
      .slice(0, 9);

    // Group plugins by category and sort by installs
    const groupedPlugins = initialPlugins.reduce((acc, plugin) => {
      const category = plugin.category;
      if (!acc[category]) {
        acc[category] = [];
      }
      acc[category].push(plugin);
      return acc;
    }, {} as Record<string, Plugin[]>);

    // Sort categories by number of plugins
    const sortedCategories = Object.entries(groupedPlugins)
      .sort(([, a], [, b]) => b.length - a.length)
      .reduce((acc, [category, plugins]) => {
        acc[category] = plugins.sort((a, b) => b.installs - a.installs);
        return acc;
      }, {} as Record<string, Plugin[]>);

    return {
      featuredApps: featured,
      mostPopular,
      integrationApps,
      sortedCategories,
    };
  }, [initialPlugins]);

  const totalIntegrationApps = initialPlugins.filter((plugin) =>
    plugin.capabilities.has('external_integration'),
  ).length;

  // Function to scroll back to top
  const scrollToTop = () => {
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  return (
    <div className="relative">
      {/* Fixed Header and Navigation */}
      <div
        ref={headerRef}
        className={`bg-[#11100d]/92 fixed inset-x-0 top-12 z-40 transform-gpu transition-all duration-300 ease-in-out ${
          headerMinimized
            ? 'border-b border-[rgba(248,244,234,0.09)] shadow-[0_18px_60px_rgba(0,0,0,0.35)] backdrop-blur-xl'
            : ''
        }`}
      >
        <div
          className={`border-b border-white/5 transition-all duration-300 ${
            headerMinimized ? 'py-2' : ''
          }`}
        >
          <div className="container mx-auto px-3 py-3 sm:px-6 sm:py-4 md:px-8 md:py-5">
            <div className="flex flex-col transition-all duration-300 sm:flex-row sm:items-center sm:space-x-6">
              {/* Title Section */}
              <div
                className={`flex-shrink-0 transform-gpu transition-all duration-300 ease-in-out ${
                  headerMinimized ? 'sm:w-48 md:w-56' : 'w-full sm:w-56 md:w-64'
                }`}
              >
                <h1
                  className={`transform-gpu text-2xl font-bold tracking-[-0.04em] text-[var(--market-ink)] transition-all duration-300 ${
                    headerMinimized ? 'text-xl sm:text-2xl' : 'sm:text-3xl md:text-4xl'
                  }`}
                >
                  App store
                </h1>
                <div
                  className={`transform-gpu overflow-hidden transition-all duration-300 ${
                    headerMinimized ? 'h-0 opacity-0' : 'h-auto opacity-100'
                  }`}
                >
                  <p className="mt-1 max-w-[26rem] text-sm leading-6 text-[var(--market-muted)] sm:mt-2 sm:text-base">
                    Practical extensions for Omi, ranked by real usage and developer fit.
                  </p>
                </div>
              </div>

              {/* Search Section */}
              <div
                className={`flex-grow transform-gpu transition-all duration-300 ${
                  headerMinimized ? 'mt-0' : 'mt-4 sm:mt-0'
                }`}
              >
                <SearchBar
                  allApps={initialPlugins}
                  onSearching={(searching) => setIsSearching(searching)}
                />
              </div>
            </div>
          </div>
        </div>

        <div className="border-b border-[rgba(248,244,234,0.08)] bg-[#15130f]/80 backdrop-blur-sm">
          <div className="container mx-auto px-3 sm:px-6 md:px-8">
            <div className="py-2 sm:py-2.5 md:py-3">
              <ScrollableCategoryNav currentCategory="" />
            </div>
          </div>
        </div>
      </div>

      {/* Main Content */}
      {!isSearching && (
        <main
          className={`relative z-0 ${
            headerMinimized
              ? 'mt-[8rem] sm:mt-[8.5rem] md:mt-[9rem]'
              : 'mt-[11rem] sm:mt-[12rem] md:mt-[13rem]'
          } transition-all duration-300`}
        >
          {/* Hero Section */}
          <div
            ref={heroRef}
            className="relative mb-14 overflow-hidden py-8 sm:py-10 md:py-16"
          >
            <div className="absolute left-1/2 top-0 h-px w-[78vw] -translate-x-1/2 bg-gradient-to-r from-transparent via-[rgba(213,168,79,0.48)] to-transparent" />
            <div className="container mx-auto px-3 sm:px-6 md:px-8">
              <div className="mb-7 grid gap-5 md:grid-cols-[1.1fr_0.9fr] md:items-end">
                <div>
                  <p className="market-kicker flex items-center gap-2">
                    <Sparkles className="h-4 w-4" />
                    Curated shelf
                  </p>
                  <h2 className="mt-3 max-w-3xl text-4xl font-bold leading-[0.94] tracking-[-0.065em] text-[var(--market-ink)] sm:text-5xl md:text-7xl">
                    The apps worth putting near your voice.
                  </h2>
                </div>
                <p className="max-w-xl text-base leading-7 text-[var(--market-muted)] md:justify-self-end">
                  Featured tools are pulled from high-install apps, then mixed so the
                  first screen feels discovered rather than machine-sorted.
                </p>
              </div>

              <div className="grid grid-cols-1 gap-4 md:auto-rows-[minmax(17rem,auto)] md:grid-cols-6">
                {featuredApps.map((plugin) => (
                  <div
                    key={plugin.id}
                    className="h-full md:[&:first-child]:col-span-3 md:[&:first-child]:row-span-2 md:[&:nth-child(2)]:col-span-3 md:[&:nth-child(3)]:col-span-3"
                  >
                    <FeaturedPluginCard
                      plugin={plugin}
                      stat={initialStats.find((s) => s.id === plugin.id)}
                    />
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div className="container mx-auto px-3 pb-20 pt-3 sm:px-6 sm:py-4 md:px-8 md:py-6">
            <div className="space-y-14 sm:space-y-16 md:space-y-24">
              {/* Developer Banner */}
              <section className="mb-8">
                <DeveloperBanner />
              </section>
              {/* Most Popular Section */}
              <section className="market-panel relative rounded-[2rem] p-4 sm:p-6 md:p-8">
                <div className="flex items-center justify-between">
                  <div className="flex items-center">
                    <Trophy className="mr-2 h-5 w-5 text-[var(--market-accent)]" />
                    <h2 className="text-xl font-bold tracking-[-0.03em] text-[var(--market-ink)] sm:text-2xl">
                      Most Popular
                    </h2>
                  </div>
                </div>
                <div className="mt-4 grid grid-cols-1 gap-y-2 sm:mt-6 sm:grid-cols-2 sm:gap-4 lg:grid-cols-3">
                  {mostPopular.map((plugin, index) => (
                    <CompactPluginCard
                      key={plugin.id}
                      plugin={plugin}
                      stat={initialStats.find((s) => s.id === plugin.id)}
                      index={index + 1}
                    />
                  ))}
                </div>
              </section>

              {/* Productivity Section - Moved to top */}
              {sortedCategories['productivity-and-organization'] && (
                <section
                  id="productivity-and-organization"
                  className="market-panel-subtle rounded-[2rem] p-4 sm:p-6 md:p-8"
                >
                  <div className="flex items-center justify-between">
                    <CategoryHeader
                      category="productivity-and-organization"
                      totalApps={sortedCategories['productivity-and-organization'].length}
                    />
                    {sortedCategories['productivity-and-organization'].length > 4 && (
                      <a
                        href="/apps/category/productivity-and-organization"
                        className="market-link flex items-center gap-1 text-sm font-semibold"
                      >
                        See all
                        <ChevronRight className="h-4 w-4" />
                      </a>
                    )}
                  </div>
                  <div className="mt-4 grid grid-cols-2 gap-3 sm:mt-6 sm:gap-4 lg:grid-cols-4">
                    {sortedCategories['productivity-and-organization']
                      ?.slice(0, 4)
                      .map((plugin) => (
                        <div key={plugin.id} className="h-full">
                          <FeaturedPluginCard
                            plugin={plugin}
                            stat={initialStats.find((s) => s.id === plugin.id)}
                          />
                        </div>
                      ))}
                  </div>
                </section>
              )}

              {/* Integration Apps Section */}
              {integrationApps.length > 0 && (
                <section className="market-panel-subtle rounded-[2rem] p-4 sm:p-6 md:p-8">
                  <div className="flex items-center justify-between">
                    <h3 className="text-lg font-semibold tracking-[-0.025em] text-[var(--market-ink)] sm:text-xl">
                      Integration Apps
                    </h3>
                    {totalIntegrationApps > 9 && (
                      <a
                        href="/apps/category/integration"
                        className="market-link flex items-center gap-1 text-sm font-semibold"
                      >
                        See all
                        <ChevronRight className="h-4 w-4" />
                      </a>
                    )}
                  </div>
                  <div className="mt-4 grid grid-cols-1 gap-y-2 sm:mt-6 sm:grid-cols-2 sm:gap-4 lg:grid-cols-3">
                    {integrationApps.map((plugin, index) => (
                      <CompactPluginCard
                        key={plugin.id}
                        plugin={plugin}
                        stat={initialStats.find((s) => s.id === plugin.id)}
                        index={index + 1}
                      />
                    ))}
                  </div>
                </section>
              )}

              {/* Category Sections - Excluding productivity */}
              {Object.entries(sortedCategories)
                .filter(([category]) => category !== 'productivity-and-organization')
                .map(([category, plugins], idx) => (
                  <section
                    key={category}
                    id={category}
                    className={`rounded-[2rem] ${
                      idx % 2 === 0
                        ? 'market-panel-subtle'
                        : 'market-panel bg-transparent'
                    } p-4 sm:p-6 md:p-8`}
                  >
                    <div className="flex items-center justify-between">
                      <CategoryHeader category={category} totalApps={plugins.length} />
                      {plugins.length > 9 && (
                        <a
                          href={`/apps/category/${category}`}
                          className="market-link flex items-center gap-1 text-sm font-semibold"
                        >
                          See all
                          <ChevronRight className="h-4 w-4" />
                        </a>
                      )}
                    </div>
                    <div className="mt-4 grid grid-cols-1 gap-y-2 sm:mt-6 sm:grid-cols-2 sm:gap-4 lg:grid-cols-3">
                      {plugins.slice(0, 9).map((plugin, index) => (
                        <CompactPluginCard
                          key={plugin.id}
                          plugin={plugin}
                          stat={initialStats.find((s) => s.id === plugin.id)}
                          index={index + 1}
                        />
                      ))}
                    </div>
                  </section>
                ))}
            </div>
          </div>

          {/* Back to top button */}
          <button
            onClick={scrollToTop}
            className="fixed bottom-6 right-6 z-50 flex h-11 w-11 items-center justify-center rounded-2xl border border-[rgba(248,244,234,0.16)] bg-[var(--market-accent)] text-[#17130b] shadow-[0_18px_48px_rgba(77,55,18,0.42)] transition-all duration-300 hover:-translate-y-1 hover:bg-[var(--market-accent-soft)] active:translate-y-0"
            aria-label="Back to top"
          >
            <ChevronUp className="h-5 w-5" />
          </button>
        </main>
      )}
    </div>
  );
}
