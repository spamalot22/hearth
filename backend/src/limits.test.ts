import { describe, expect, it } from 'vitest';

import { RateLimiter } from './limits';

describe('RateLimiter', () => {
  it('allows up to the limit, then blocks within the window', () => {
    const rl = new RateLimiter(3, 1000);
    expect(rl.allow('k', 0)).toBe(true);
    expect(rl.allow('k', 100)).toBe(true);
    expect(rl.allow('k', 200)).toBe(true);
    expect(rl.allow('k', 300)).toBe(false); // 4th within the window
  });

  it('slides the window so old hits expire', () => {
    const rl = new RateLimiter(2, 1000);
    expect(rl.allow('k', 0)).toBe(true);
    expect(rl.allow('k', 500)).toBe(true);
    expect(rl.allow('k', 600)).toBe(false); // both still in window
    expect(rl.allow('k', 1100)).toBe(true); // the t=0 hit has aged out
  });

  it('keys are independent', () => {
    const rl = new RateLimiter(1, 1000);
    expect(rl.allow('a', 0)).toBe(true);
    expect(rl.allow('b', 0)).toBe(true); // different key, own budget
    expect(rl.allow('a', 1)).toBe(false);
  });
});
