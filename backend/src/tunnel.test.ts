// SPDX-License-Identifier: AGPL-3.0-or-later
import { describe, it, expect } from 'vitest';
import { Hono } from 'hono';
import { TunnelHub, addTunnelRoutes } from './tunnel';

const aliceHex = 'a'.repeat(64);
const bobHex = 'b'.repeat(64);

function makeApp(verifyToken: (t: string, now: number) => string | null) {
  const app = new Hono();
  const hub = new TunnelHub();
  addTunnelRoutes(app, hub, verifyToken);
  return app;
}

const alwaysValid = (token: string) => token; // token IS the pubkey

describe('tunnel', () => {
  describe('TunnelHub', () => {
    it('posts and drains frames', () => {
      const hub = new TunnelHub();
      hub.post('alice', 'bob', 'frame1', 1000);
      hub.post('alice', 'bob', 'frame2', 1001);
      const frames = hub.drain('alice', 'bob', 1002);
      expect(frames).toEqual(['frame1', 'frame2']);
    });

    it('drain empties the buffer', () => {
      const hub = new TunnelHub();
      hub.post('alice', 'bob', 'frame1', 1000);
      hub.drain('alice', 'bob', 1001);
      expect(hub.drain('alice', 'bob', 1002)).toEqual([]);
    });

    it('prunes stale entries on drain', () => {
      const hub = new TunnelHub();
      hub.post('alice', 'bob', 'old', 0);
      hub.post('alice', 'bob', 'fresh', 299000);
      const frames = hub.drain('alice', 'bob', 300001);
      expect(frames).toEqual(['fresh']);
    });

    it('caps a pair at 512 frames and paginates drains', () => {
      const hub = new TunnelHub();
      for (let i = 0; i < 600; i++) {
        hub.post('a', 'b', `f${i}`, 1000);
      }
      const frames: string[] = [];
      for (let page = 0; page < 16; page++) {
        frames.push(...hub.drain('a', 'b', 1001));
      }
      expect(frames.length).toBe(512);
      expect(frames[0]).toBe('f88');
      expect(frames.at(-1)).toBe('f599');
      expect(hub.drain('a', 'b', 1001)).toEqual([]);
    });

    it('caps buffered bytes per pair', () => {
      const hub = new TunnelHub();
      const fragment = 'x'.repeat(60 * 1024);
      for (let i = 0; i < 500; i++) {
        hub.post('a', 'b', fragment, 1000);
      }
      let count = 0;
      for (let page = 0; page < 16; page++) {
        count += hub.drain('a', 'b', 1001).length;
      }
      expect(count).toBeLessThanOrEqual(409);
    });

    it('separate directions are independent', () => {
      const hub = new TunnelHub();
      hub.post('alice', 'bob', 'a2b', 1000);
      hub.post('bob', 'alice', 'b2a', 1000);
      expect(hub.drain('alice', 'bob', 1001)).toEqual(['a2b']);
      expect(hub.drain('bob', 'alice', 1001)).toEqual(['b2a']);
    });

    it('evicts the oldest pair once over the pair cap', () => {
      const hub = new TunnelHub();
      // Simulate an attacker posting to many never-drained recipients. The
      // first pair should be evicted (LRU) rather than growing unbounded.
      for (let i = 0; i < 10_001; i++) {
        hub.post('attacker', `victim${i}`, 'x', 1000);
      }
      // The very first pair was pushed out; a recent one survives.
      expect(hub.drain('attacker', 'victim0', 1001)).toEqual([]);
      expect(hub.drain('attacker', 'victim10000', 1001)).toEqual(['x']);
    });

    it('re-posting an existing pair keeps it fresh (LRU touch)', () => {
      const hub = new TunnelHub();
      hub.post('attacker', 'victim0', 'keep', 1000);
      for (let i = 1; i < 2048; i++) {
        hub.post('attacker', `victim${i}`, 'x', 1000);
      }
      // Touch victim0 so it is no longer the oldest, then overflow the global
      // frame cap. A less-recent pair is evicted instead.
      hub.post('attacker', 'victim0', 'keep2', 1001);
      hub.post('attacker', 'victim-new', 'x', 1002);
      // victim0 survived because the touch moved it to the end.
      expect(hub.drain('attacker', 'victim0', 1003)).toEqual(['keep', 'keep2']);
    });
  });

  describe('POST /tunnel', () => {
    it('returns 400 without required fields', async () => {
      const app = makeApp(alwaysValid);
      const res = await app.request('/tunnel', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ from: 'a' }),
      });
      expect(res.status).toBe(400);
    });

    it('returns 403 without token', async () => {
      const app = makeApp(alwaysValid);
      const res = await app.request('/tunnel', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ from: aliceHex, to: bobHex, data: 'x' }),
      });
      expect(res.status).toBe(403);
    });

    it('returns 403 for invalid token', async () => {
      const app = makeApp(() => null);
      const res = await app.request('/tunnel', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: 'Bearer bad',
        },
        body: JSON.stringify({
          from: aliceHex,
          to: bobHex,
          data: 'x',
        }),
      });
      expect(res.status).toBe(403);
    });

    it('posts successfully with valid token', async () => {
      const app = makeApp(alwaysValid);
      const res = await app.request('/tunnel', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${aliceHex}`,
        },
        body: JSON.stringify({
          from: aliceHex,
          to: bobHex,
          data: 'hello',
        }),
      });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ ok: true });
    });

    it('rejects a tunnel fragment over 60 KiB', async () => {
      const app = makeApp(alwaysValid);
      const res = await app.request('/tunnel', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${aliceHex}`,
        },
        body: JSON.stringify({
          from: aliceHex,
          to: bobHex,
          data: 'x'.repeat(60 * 1024 + 1),
        }),
      });
      expect(res.status).toBe(413);
    });

    it('returns 400 for malformed json and invalid pubkeys', async () => {
      const app = makeApp(alwaysValid);
      const malformed = await app.request('/tunnel', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{',
      });
      expect(malformed.status).toBe(400);

      const invalidKey = await app.request('/tunnel', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: 'Bearer alice',
        },
        body: JSON.stringify({
          from: 'alice',
          to: bobHex,
          data: 'hello',
        }),
      });
      expect(invalidKey.status).toBe(400);
    });
  });

  describe('GET /tunnel', () => {
    it('returns 400 without from/to', async () => {
      const app = makeApp(alwaysValid);
      const res = await app.request('/tunnel?from=a');
      expect(res.status).toBe(400);
    });

    it('returns 403 without token', async () => {
      const app = makeApp(alwaysValid);
      const res = await app.request(`/tunnel?from=${aliceHex}&to=${bobHex}`);
      expect(res.status).toBe(403);
    });

    it('drains posted frames', async () => {
      const hub = new TunnelHub();
      const app = new Hono();
      addTunnelRoutes(app, hub, alwaysValid);

      // Post a frame
      await app.request('/tunnel', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${aliceHex}`,
        },
        body: JSON.stringify({
          from: aliceHex,
          to: bobHex,
          data: 'msg1',
        }),
      });

      // Drain it
      const res = await app.request(`/tunnel?from=${aliceHex}&to=${bobHex}`, {
        headers: { authorization: `Bearer ${bobHex}` },
      });
      expect(res.status).toBe(200);
      const body = (await res.json()) as { frames: string[] };
      expect(body.frames).toEqual(['msg1']);

      // Second drain is empty
      const res2 = await app.request(`/tunnel?from=${aliceHex}&to=${bobHex}`, {
        headers: { authorization: `Bearer ${bobHex}` },
      });
      expect(((await res2.json()) as { frames: string[] }).frames).toEqual([]);
    });
  });
});
