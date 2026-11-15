import {mkdir} from 'node:fs/promises';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';

// Test tooling only: ctypes avoids a dependency on certutil or NSS headers.
const importCA = String.raw`
import base64, ctypes as c, ctypes.util, os, re, sys
class Item(c.Structure):
    _fields_ = [('type', c.c_uint), ('data', c.POINTER(c.c_ubyte)), ('len', c.c_uint)]
class Trust(c.Structure):
    _fields_ = [('ssl', c.c_uint), ('email', c.c_uint), ('objects', c.c_uint)]
nss = c.CDLL(ctypes.util.find_library('nss3') or 'libnss3.so')
def bind(name, result, *args):
    fn = getattr(nss, name); fn.restype = result; fn.argtypes = list(args); return fn
def checked(name, result):
    if result != 0: raise RuntimeError(name + ' failed: ' + str(result))
init = bind('NSS_InitReadWrite', c.c_int, c.c_char_p)
shutdown = bind('NSS_Shutdown', c.c_int)
database = bind('CERT_GetDefaultCertDB', c.c_void_p)
create = bind('CERT_NewTempCertificate', c.c_void_p, c.c_void_p, c.POINTER(Item), c.c_char_p, c.c_int, c.c_int)
slot = bind('PK11_GetInternalKeySlot', c.c_void_p)
free_slot = bind('PK11_FreeSlot', None, c.c_void_p)
needs_pin = bind('PK11_NeedUserInit', c.c_int, c.c_void_p)
init_pin = bind('PK11_InitPin', c.c_int, c.c_void_p, c.c_char_p, c.c_char_p)
authenticate = bind('PK11_Authenticate', c.c_int, c.c_void_p, c.c_int, c.c_void_p)
import_cert = bind('PK11_ImportCert', c.c_int, c.c_void_p, c.c_void_p, c.c_uint, c.c_char_p, c.c_int)
find = bind('CERT_FindCertByNickname', c.c_void_p, c.c_void_p, c.c_char_p)
change = bind('CERT_ChangeCertTrust', c.c_int, c.c_void_p, c.c_void_p, c.POINTER(Trust))
get_trust = bind('CERT_GetCertTrust', c.c_int, c.c_void_p, c.POINTER(Trust))
destroy = bind('CERT_DestroyCertificate', None, c.c_void_p)
password_type = c.CFUNCTYPE(c.c_void_p, c.c_void_p, c.c_int, c.c_void_p)
set_password = bind('PK11_SetPasswordFunc', None, password_type)
libc = c.CDLL(None); libc.strdup.argtypes = [c.c_char_p]; libc.strdup.restype = c.c_void_p
password = password_type(lambda slot, retry, context: libc.strdup(b''))
set_password(password)
checked('NSS_InitReadWrite', init(('sql:' + os.path.abspath(sys.argv[1])).encode()))
db = database(); nickname = b'Titan browser network test CA'
if len(sys.argv) > 2:
    pem = open(sys.argv[2], 'rb').read()
    der = base64.b64decode(re.search(b'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', pem, re.S).group(1))
    data = (c.c_ubyte * len(der)).from_buffer_copy(der)
    item = Item(0, data, len(der))
    certificate = create(db, c.byref(item), nickname, 0, 1)
    if not certificate: raise RuntimeError('NSS did not decode the test CA')
    token = slot()
    if needs_pin(token): checked('PK11_InitPin', init_pin(token, None, None))
    checked('PK11_Authenticate', authenticate(token, 1, None))
    checked('PK11_ImportCert', import_cert(token, certificate, 0, nickname, 0))
    destroy(certificate); free_slot(token)
    certificate = find(db, nickname)
    if not certificate: raise RuntimeError('NSS did not persist the test CA')
    checked('CERT_ChangeCertTrust', change(db, certificate, c.byref(Trust(0x18, 0, 0))))
    destroy(certificate)
else:
    certificate = find(db, nickname)
    if not certificate: raise RuntimeError('NSS test CA is missing on read-back')
    trust = Trust(); checked('CERT_GetCertTrust', get_trust(certificate, c.byref(trust)))
    if trust.ssl & 0x18 != 0x18: raise RuntimeError('NSS test CA is not trusted')
    destroy(certificate)
checked('NSS_Shutdown', shutdown())
`;

export async function chromiumTrust(home, ca) {
  if (process.platform !== 'linux') return false;
  const db = join(home, '.pki', 'nssdb');
  await mkdir(db, {recursive: true});
  for (const args of [[db, ca], [db]]) {
    const result = spawnSync('python3', ['-c', importCA, ...args], {encoding: 'utf8'});
    if (result.error || result.status !== 0) {
      throw new Error('isolated Chromium NSS setup failed: ' + (result.stderr || result.error));
    }
  }
  return true;
}
