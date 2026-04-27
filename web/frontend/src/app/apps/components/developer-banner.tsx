'use client';

import Link from 'next/link';
import { Brackets, Zap, ArrowRight } from 'lucide-react';
import { useState, useEffect } from 'react';

export const DeveloperBanner = () => {
  const [codeStep, setCodeStep] = useState(0);
  const codeLines = [
    'export default async function onMemory(event) {',
    '  const brief = await omi.summarize(event.transcript)',
    '  return {',
    '    title: brief.nextStep,',
    '    destination: "team-notes",',
    '    confidence: 0.84',
    '  }',
    '}',
  ];

  useEffect(() => {
    const interval = setInterval(() => {
      setCodeStep((prev) => (prev + 1) % codeLines.length);
    }, 1200);
    return () => clearInterval(interval);
  }, [codeLines.length]);

  return (
    <div className="container mx-auto px-3 sm:px-6 md:px-8">
      <Link
        href="https://docs.omi.me/doc/developer/apps/Introduction"
        target="_blank"
        className="group block w-full transform transition-transform duration-300 hover:-translate-y-1 active:translate-y-0"
      >
        <div className="relative overflow-hidden rounded-[2rem] border border-[rgba(248,244,234,0.12)] bg-[#211d14] shadow-[0_28px_90px_rgba(77,55,18,0.34)]">
          {/* Background pattern */}
          <div className="absolute inset-0 opacity-80">
            <div className="absolute -right-20 -top-24 h-72 w-72 rounded-full bg-[rgba(213,168,79,0.18)] blur-3xl"></div>
            <div className="absolute -bottom-24 left-10 h-56 w-56 rounded-full bg-[rgba(255,248,231,0.1)] blur-3xl"></div>
            <div className="absolute bottom-0 right-0 h-px w-2/3 bg-gradient-to-r from-transparent via-[rgba(213,168,79,0.52)] to-transparent"></div>
          </div>

          <div className="absolute right-5 top-5">
            <Brackets className="h-5 w-5 text-[var(--market-accent-soft)]" />
          </div>

          <div className="relative z-10 flex h-auto flex-col p-6 sm:h-[12rem] sm:flex-row sm:items-center sm:justify-between sm:p-8 md:p-10">
            {/* Left content */}
            <div className="flex flex-col sm:max-w-xs md:max-w-sm">
              <p className="market-kicker">Developer shelf</p>
              <h3 className="mt-3 text-2xl font-bold leading-none tracking-[-0.055em] text-[var(--market-ink)] sm:text-3xl md:text-4xl">
                Build where the memory happens.
              </h3>
              <p className="mt-3 text-sm leading-6 text-[var(--market-muted)] sm:text-base">
                Connect to conversations, actions, and context without forcing users
                through another dashboard.
              </p>
            </div>

            {/* Middle - Code typing animation */}
            <div className="mt-4 hidden sm:mt-0 sm:block sm:max-w-md sm:flex-1">
              <div className="bg-black/28 h-[9.5rem] overflow-hidden rounded-[1.25rem] border border-[rgba(248,244,234,0.1)] p-3 font-mono text-xs text-[#f1d58e]/90 backdrop-blur-sm">
                <div className="h-full">
                  {codeLines.slice(0, codeStep + 1).map((line, i) => (
                    <div key={i} className="whitespace-pre">
                      {line}
                      {i === codeStep && (
                        <span className="ml-0.5 inline-block h-3 w-1.5 animate-pulse bg-[var(--market-accent-soft)]"></span>
                      )}
                    </div>
                  ))}
                  {/* Empty lines to maintain height */}
                  {Array(9 - codeStep)
                    .fill(0)
                    .map((_, i) => (
                      <div key={`empty-${i}`} className="whitespace-pre">
                        &nbsp;
                      </div>
                    ))}
                </div>
              </div>
            </div>

            {/* Right - Button */}
            <div className="mt-4 flex items-center sm:ml-4 sm:mt-0">
              <div className="flex items-center gap-1.5 rounded-2xl bg-[var(--market-accent)] px-4 py-2 text-sm font-bold text-[#17130b] shadow-[0_16px_42px_rgba(77,55,18,0.35)] transition-all duration-300 group-hover:bg-[var(--market-accent-soft)]">
                <Zap className="h-3.5 w-3.5" />
                <span>Start Building</span>
                <ArrowRight className="h-3.5 w-3.5 opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
              </div>
            </div>
          </div>

          {/* Subtle border glow */}
          <div className="absolute inset-0 rounded-[2rem] shadow-[inset_0_1px_0_rgba(255,255,255,0.12)]"></div>
        </div>
      </Link>
    </div>
  );
};
