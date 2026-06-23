import 'dotenv/config'; // loads backend/.env (gitignored) into process.env

import { serve } from '@hono/node-server';

import { createRelay } from './relay';

const port = Number(process.env.PORT ?? '8787');

serve({ fetch: createRelay().fetch, port }, (info) => {
  // eslint-disable-next-line no-console
  console.log(`Hearth relay listening on http://localhost:${info.port}`);
});
