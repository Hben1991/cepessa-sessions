/* eslint-disable prettier/prettier */
'use client';

import Link from 'next/link';
import { useRef, useEffect } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { categoryMetadata } from '../../utils/category';

interface ScrollableCategoryNavProps {
  currentCategory: string;
}

export function ScrollableCategoryNav({ currentCategory }: ScrollableCategoryNavProps) {
  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const categories = Object.values(categoryMetadata);

  // Scroll to active category on mount
  useEffect(() => {
    const container = scrollContainerRef.current;
    const activeItem = container?.querySelector('[data-active="true"]');

    if (container && activeItem) {
      const containerWidth = container.offsetWidth;
      const itemLeft = (activeItem as HTMLElement).offsetLeft;
      const itemWidth = (activeItem as HTMLElement).offsetWidth;

      // Center the active item
      container.scrollLeft = itemLeft - containerWidth / 2 + itemWidth / 2;
    }
  }, [currentCategory]);

  const scroll = (direction: 'left' | 'right') => {
    const container = scrollContainerRef.current;
    if (!container) return;

    const scrollAmount = container.offsetWidth * 0.8;
    const targetScroll =
      container.scrollLeft + (direction === 'left' ? -scrollAmount : scrollAmount);

    container.scrollTo({
      left: targetScroll,
      behavior: 'smooth',
    });
  };

  return (
    <div className="relative">
      {/* Left scroll button */}
      <button
        onClick={() => scroll('left')}
        className="absolute -left-4 top-1/2 z-10 flex h-8 w-8 -translate-y-1/2 items-center justify-center rounded-xl border border-[rgba(248,244,234,0.08)] bg-[#1b1914] text-[var(--market-muted)] shadow-lg transition-colors hover:text-[var(--market-ink)]"
      >
        <ChevronLeft className="h-5 w-5" />
      </button>

      {/* Scrollable container */}
      <div
        ref={scrollContainerRef}
        className="no-scrollbar flex items-center space-x-2 overflow-x-auto scroll-smooth px-4"
      >
        {categories.map((category) => (
          <Link
            key={category.id}
            href={`/apps/category/${category.id}`}
            data-active={currentCategory === category.id}
            className={`
              flex items-center space-x-2 rounded-2xl px-4 py-2 transition-all
              ${
                currentCategory === category.id
                  ? 'bg-[rgba(213,168,79,0.14)] text-[var(--market-accent-soft)]'
                  : 'text-[var(--market-muted)] hover:bg-white/5 hover:text-[var(--market-ink)]'
              }
            `}
          >
            <category.icon className="h-4 w-4" />
            <span className="whitespace-nowrap text-sm font-medium">
              {category.displayName}
            </span>
          </Link>
        ))}
      </div>

      {/* Right scroll button */}
      <button
        onClick={() => scroll('right')}
        className="absolute -right-4 top-1/2 z-10 flex h-8 w-8 -translate-y-1/2 items-center justify-center rounded-xl border border-[rgba(248,244,234,0.08)] bg-[#1b1914] text-[var(--market-muted)] shadow-lg transition-colors hover:text-[var(--market-ink)]"
      >
        <ChevronRight className="h-5 w-5" />
      </button>
    </div>
  );
}
