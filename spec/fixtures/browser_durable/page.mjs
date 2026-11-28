// The durable storage gate's page: the instance host, for the gate to call,
// and the Content Security Policy violations the page has seen. It is an
// external module so that a page served with `script-src 'self'` runs it.
import * as host from './host.mjs';

const violations = [];
document.addEventListener('securitypolicyviolation', event => {
  violations.push(`${event.effectiveDirective} ${event.blockedURI}`);
});
globalThis.titanDurable = {...host, violations: () => [...violations]};
