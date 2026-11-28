// Titan's browser SQLite transport. titan:sqlite3 carries the opaque request
// and reply frames that titan/sqlite3's Titan codec builds and the storage
// worker's SQLite service answers; the transport reads only a frame's
// header. It keeps the one ledger of which Lua state owns each connection
// and which connection each statement belongs to: a state reaches only its
// own connections, and a closing state's connections, one opened for a state
// that closed meanwhile, and those still left at disposal are closed by
// their generation-tagged id. A linked image module embeds this file only
// when the image links titan.sqlite3, and names titanBrowserSql as its image
// binding's `sql`.
// Wire format: doc/implementation/sqlite3-library.md#browser-service-frames

const opOpen = 1, opPrepare = 2, opFinalize = 7, opClose = 8, opCloseConn = 9, opRollback = 13, inTransit = 0;

/** The image binding's `sql`: the connection ledger of one instance's storage. */
export function titanBrowserSql(storage) {
  const leases = new Map(), statements = new Map(), nonce = crypto.getRandomValues(new BigInt64Array(1))[0];
  const {states} = storage.owner;
  const ledger = {transaction: false, binding, retire(state, id) { if (leases.get(id) === state) retire(id); },
    closeState(state) { for (const [id, owner] of leases) if (owner === state) retire(id); },
    retireAll() { for (const id of leases.keys()) retire(id); }};
  // Every reply says whether some connection holds an open transaction.
  const send = (frame, cwd) => storage.dispatch(frame, cwd).then(reply => {
    ledger.transaction = reply[2] !== 0;
    return reply;
  });
  // CLOSE_CONN, the ledger's alone, finalizes the connection's statements and closes it.
  function retire(id) {
    leases.delete(id);
    for (const [statement, conn] of statements) if (conn === id) statements.delete(statement);
    const frame = new Uint8Array(16);
    frame[0] = opCloseConn;
    frame[1] = 1;
    new DataView(frame.buffer).setBigUint64(8, id, true);
    send(frame).catch(() => { /* A stopped worker took the connection with it. */ });
  }
  // `call` sends a frame on a connection the state owns, run in the state's
  // working directory when `cwd` names one; `detach` and `adopt` move a
  // connection between states through a payload stamped with this instance's
  // nonce.
  function binding(state) {
    return (command, value, id) => {
      if (command === 'call') {
        if (!(value instanceof Uint8Array) || value.byteLength < 16) throw new TypeError('titan:sqlite3 frame is too short');
        const op = value[0], target = new DataView(value.buffer, value.byteOffset, 16).getBigUint64(8, true);
        const conn = op > opPrepare && op <= opFinalize ? statements.get(target) : target;
        if (op < opOpen || op > opRollback || op === opCloseConn || op !== opOpen && leases.get(conn) !== state) {
          throw new Error('titan:sqlite3 frame names a connection this state does not own');
        }
        return {kind: 'retained', promise: send(value, typeof id === 'string' ? id : undefined).then(reply => {
          // FINALIZE consumes the statement even when SQLite reports an error.
          if (op === opFinalize && reply[1] !== 2) statements.delete(target);
          if (reply[1] !== 0) return reply;
          const handle = new DataView(reply.buffer, reply.byteOffset, 16).getBigUint64(8, true);
          if (op === opOpen && states.get(state) === 'open') leases.set(handle, state);
          else if (op === opOpen) retire(handle);
          else if (op === opPrepare && leases.has(conn)) statements.set(handle, conn);
          else if (op === opClose) leases.delete(conn);
          return reply;
        })};
      }
      if (command === 'detach' && leases.get(BigInt.asUintN(64, value)) === state) {
        leases.set(BigInt.asUintN(64, value), inTransit);
        return nonce;
      }
      if (command === 'adopt' && value === nonce && states.get(state) === 'open' &&
          leases.get(BigInt.asUintN(64, id)) === inTransit) {
        leases.set(BigInt.asUintN(64, id), state);
        return;
      }
      throw new Error(`titan:sqlite3 cannot ${command} this connection here`);
    };
  }
  return ledger;
}
