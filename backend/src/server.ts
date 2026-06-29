// SPDX-License-Identifier: AGPL-3.0-or-later
// Production entry point — env vars injected by Docker, no .env file needed.
import { serve } from '@hono/node-server';

import { createRelay } from './relay';

const port = Number(process.env.PORT ?? '8787');

serve({ fetch: createRelay().fetch, port }, (info) => {
  // eslint-disable-next-line no-console
  console.log(`Hearth relay listening on http://localhost:${info.port}`);
});
