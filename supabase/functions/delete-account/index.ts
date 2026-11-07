import { createClient } from 'npm:@supabase/supabase-js@2';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const respond = (status: number, message: string) =>
  new Response(JSON.stringify({ message }), { status, headers });

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers });
  if (request.method !== 'POST') return respond(405, 'Method not allowed.');
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return respond(401, 'Sign in again.');
  const url = Deno.env.get('SUPABASE_URL')!;
  const options = { auth: { persistSession: false, autoRefreshToken: false } };
  const client = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, options);
  const { data: { user }, error } = await client.auth.getUser(authorization.slice(7));
  if (error || !user?.email) return respond(401, 'Sign in again.');
  let password: unknown;
  try { ({ password } = await request.json()); }
  catch { return respond(400, 'Invalid request.'); }
  if (typeof password !== 'string' || !password || password.length > 4096) {
    return respond(400, 'Enter your password.');
  }
  // Verify the password server-side; the authenticated user cannot supply a target ID.
  const { data: verified, error: passwordError } = await client.auth.signInWithPassword({
    email: user.email, password,
  });
  if (passwordError || verified.user?.id !== user.id) {
    return respond(403, 'Incorrect password.');
  }
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, options);
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) return respond(500, 'Unable to delete account.');
  return respond(200, 'Account deleted.');
});
