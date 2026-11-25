import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const memberSelect = document.getElementById('member-select');
const eventsEl = document.getElementById('events');
const statusEl = document.getElementById('status');

const LABELS = {
  attending: 'Attending',
  not_attending: 'Not attending',
  no_response: 'No response yet',
};

let members = [];          // [{ id, name }]
let events = [];           // [{ id, title, event_date, ... }]
let rsvpsByEvent = {};     // { eventId: [{ member_id, member_name, status }] }
let selectedMemberId = safeGet('rsvp_member_id') || '';

// ---------- small helpers ----------

function safeGet(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}
function safeSet(key, value) {
  try { localStorage.setItem(key, value); } catch { /* private mode etc. */ }
}

// Build DOM elements safely (textContent, never innerHTML) so a member
// name can never inject markup into the page.
function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children) if (c) node.append(c);
  return node;
}

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.className = isError ? 'error' : '';
}

function formatDate(iso) {
  return new Date(iso).toLocaleString(undefined, {
    weekday: 'long', month: 'long', day: 'numeric',
    hour: 'numeric', minute: '2-digit',
  });
}

// ---------- loading data from Supabase ----------

async function loadAll() {
  setStatus('Loading…');

  // 1. Members (for the "I am…" dropdown)
  const membersRes = await supabase
    .from('members')
    .select('id, name')
    .eq('active', true)
    .order('name');
  if (membersRes.error) return fail(membersRes.error);
  members = membersRes.data;

  // 2. Upcoming events
  const eventsRes = await supabase
    .from('events')
    .select('*')
    .gte('event_date', new Date().toISOString())
    .order('event_date');
  if (eventsRes.error) return fail(eventsRes.error);
  events = eventsRes.data;

  // 3. Everyone's status for every upcoming event (one call per event)
  const results = await Promise.all(
    events.map((ev) => supabase.rpc('get_event_rsvps', { p_event_id: ev.id }))
  );
  rsvpsByEvent = {};
  for (let i = 0; i < events.length; i++) {
    if (results[i].error) return fail(results[i].error);
    rsvpsByEvent[events[i].id] = results[i].data;
  }

  setStatus('');
  render();
}

function fail(error) {
  console.error(error);
  setStatus('Something went wrong loading the data. Please refresh, or tell an organizer.', true);
}

// ---------- rendering ----------

function renderMemberSelect() {
  memberSelect.replaceChildren(
    el('option', { value: '', text: 'Select your name…' }),
    ...members.map((m) => el('option', { value: m.id, text: m.name }))
  );
  // Only restore a remembered name if that member still exists.
  if (members.some((m) => m.id === selectedMemberId)) {
    memberSelect.value = selectedMemberId;
  } else {
    selectedMemberId = '';
  }
}

function render() {
  renderMemberSelect();

  if (events.length === 0) {
    eventsEl.replaceChildren(el('p', { class: 'hint', text: 'No upcoming events yet.' }));
    return;
  }
  eventsEl.replaceChildren(...events.map(renderEvent));
}

function renderEvent(ev) {
  const rows = rsvpsByEvent[ev.id] || [];
  const groups = {
    attending: rows.filter((r) => r.status === 'attending'),
    not_attending: rows.filter((r) => r.status === 'not_attending'),
    no_response: rows.filter((r) => r.status === 'no_response'),
  };

  const mine = rows.find((r) => r.member_id === selectedMemberId);

  // Action area depends on who's selected and whether they've responded.
  let actionArea;
  if (!selectedMemberId) {
    actionArea = el('p', { class: 'hint', text: 'Select your name above to respond.' });
  } else if (mine && mine.status !== 'no_response') {
    actionArea = el('div', {
      class: 'locked',
      text: `${mine.member_name}: ${LABELS[mine.status]}. This is locked. Contact an organizer if you need to change it.`,
    });
  } else {
    actionArea = el(
      'div',
      { class: 'actions' },
      el('button', { class: 'btn-yes', text: 'Attending', onclick: () => submit(ev, 'attending') }),
      el('button', { class: 'btn-no', text: 'Not attending', onclick: () => submit(ev, 'not_attending') })
    );
  }

  const nameList = (list) =>
    el('ul', { class: 'names' }, ...list.map((r) => el('li', { text: r.member_name })));

  const section = (key, cls, open) => {
    const d = el(
      'details', {},
      el('summary', { text: `${LABELS[key]} (${groups[key].length})` }),
      groups[key].length ? nameList(groups[key]) : el('p', { class: 'hint', text: 'Nobody yet.' })
    );
    if (open) d.open = true;
    return d;
  };

  return el(
    'article',
    { class: 'event' },
    el('h2', { text: ev.title }),
    el('p', { class: 'meta', text: [formatDate(ev.event_date), ev.location].filter(Boolean).join(' · ') }),
    ev.notes ? el('p', { class: 'notes', text: ev.notes }) : null,
    actionArea,
    el(
      'div',
      { class: 'counts' },
      el('span', { class: 'pill yes', text: `${groups.attending.length} attending` }),
      el('span', { class: 'pill no', text: `${groups.not_attending.length} not attending` }),
      el('span', { class: 'pill maybe', text: `${groups.no_response.length} no response` })
    ),
    section('attending', 'yes', true),
    section('not_attending', 'no', false),
    section('no_response', 'maybe', false)
  );
}

// ---------- submitting an RSVP ----------

async function submit(ev, status) {
  const member = members.find((m) => m.id === selectedMemberId);
  if (!member) return;

  // Confirm first: the lock makes mistakes (like the wrong name) costly.
  const ok = window.confirm(
    `Mark ${member.name} as "${LABELS[status]}" for ${ev.title}?\n\n` +
    `This can't be changed afterward without an organizer.`
  );
  if (!ok) return;

  setStatus('Saving…');
  const { data, error } = await supabase.rpc('submit_rsvp', {
    p_member_id: member.id,
    p_event_id: ev.id,
    p_status: status,
  });

  if (error) {
    console.error(error);
    setStatus('Could not save your response. Please try again.', true);
    return;
  }

  const messages = {
    saved: ['Saved. Thanks!', false],
    already_set: ['A response was already recorded for this person, so nothing was changed.', false],
    event_closed: ['This event has already started, so RSVPs are closed.', true],
  };
  const [message, isError] = messages[data] || ['Done.', false];

  // Re-fetch so the page shows the true current state either way.
  await loadAll();
  setStatus(message, isError);
}

// ---------- wire up ----------

memberSelect.addEventListener('change', () => {
  selectedMemberId = memberSelect.value;
  safeSet('rsvp_member_id', selectedMemberId);
  render();
});

loadAll();
