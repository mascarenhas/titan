// Regenerates the vendored uwasi regions of the browser storage runtime from
// vendor/uwasi/src, so the checked-in titan-runtime/browser/ files are plain
// zero-dependency JavaScript and building the browser SDK needs no
// TypeScript toolchain, bun or npm. Node's type stripping removes the types;
// this script lowers the one construct stripping refuses (constructor
// parameter properties), joins the modules into one scope, and replaces the
// text between each target's marker lines. The worker also receives a copy
// of the storage core authored in titan-browser-vfs.mjs. `--check` reports
// stale targets instead of writing them.
//
//   node scripts/build_uwasi_bundle.mjs [--check]
//
// Implementation notes: doc/implementation/browser-target.md#the-browser-storage-runtime
import {readFileSync, writeFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {dirname, join, posix, relative} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const vendor = join(root, 'vendor/uwasi/src');
const browser = join(root, 'titan-runtime/browser');
const UPSTREAM = '11b4ebf5fef47d49eb7da8a9d21483cf921e1a6c';

// Node reports type stripping as experimental; the output is what is checked.
process.removeAllListeners('warning');

// The end of the bracketed group that opens at `start`.
function closing(source, start) {
  let depth = 0, at = start;
  do {
    if ('([{'.includes(source[at])) depth++;
    else if (')]}'.includes(source[at])) depth--;
    at++;
  } while (depth > 0);
  return at;
}

// `constructor(private readonly store: T, ...) {` becomes plain parameters
// and assignments, after `super(...)` when there is one, as TypeScript emits.
function lowerParameterProperties(source, file) {
  let at = 0, out = '';
  for (;;) {
    const start = source.indexOf('constructor(', at);
    if (start < 0) return out + source.slice(at);
    const end = closing(source, start + 'constructor'.length);
    const parameters = [], fields = [];
    let piece = '', nesting = 0;
    for (const char of source.slice(start + 'constructor('.length, end - 1) + ',') {
      if ('([{'.includes(char)) nesting++;
      else if (')]}'.includes(char)) nesting--;
      if (char !== ',' || nesting > 0) { piece += char; continue; }
      const match = /^(\s*)((?:(?:public|private|protected|readonly)\s+)+)([A-Za-z_$][\w$]*)/.exec(piece);
      if (match) {
        fields.push(match[3]);
        piece = match[1] + piece.slice(match[1].length + match[2].length);
      }
      if (piece.trim()) parameters.push(piece);
      piece = '';
    }
    if (!fields.length) {
      out += source.slice(at, end);
      at = end;
      continue;
    }
    const open = source.indexOf('{', end), body = closing(source, open);
    if (/\S/.test(source.slice(end, open))) throw new Error(`${file}: unexpected constructor shape`);
    const call = source.indexOf('super(', open);
    const insert = call >= 0 && call < body ? source.indexOf(';', closing(source, call + 5)) + 1 : open + 1;
    out += source.slice(at, start) + 'constructor(' + parameters.join(',') + ')' + source.slice(end, insert) +
      fields.map(name => ` this.${name} = ${name};`).join('');
    at = insert;
  }
}

const importPattern = /^import\s*\{([^}]*)\}\s*from\s*"(\.[^"]+)";[ \t]*\n?/gm;
const reexportPattern = /^export\s*(?:\{([^}]*)\}|\*)\s*from\s*"(\.[^"]+)";[ \t]*\n?/gm;
const declarationPattern = /^export\s+((?:async\s+)?function\*?\s*|class\s+|const\s+|let\s+)([A-Za-z_$][\w$]*)/gm;

function names(list) {
  return list.replace(/\/\/[^\n]*|\/\*[\s\S]*?\*\//g, '').split(',').map(entry => entry.trim()).filter(Boolean).map(entry => {
    const [name, alias = name] = entry.split(/\s+as\s+/);
    return {name, alias};
  });
}

// Module ids are POSIX paths below vendor/uwasi/src on every host, so the
// output does not depend on the path separator.
function resolve(from, specifier) {
  return posix.join(posix.dirname(from), specifier.replace(/\.js$/, '.ts'));
}

// Every module reachable from `entries`, stripped, with its imports,
// re-exports and declared exports.
function load(entries) {
  const modules = new Map();
  const visit = file => {
    if (modules.has(file)) return;
    const source = readFileSync(join(vendor, file), 'utf8');
    const code = stripTypeScriptTypes(lowerParameterProperties(source, file));
    const module = {file, code, imports: [], reexports: [], declared: []};
    modules.set(file, module);
    for (const [, list, specifier] of code.matchAll(importPattern)) {
      module.imports.push({from: resolve(file, specifier), names: names(list)});
    }
    for (const [, list, specifier] of code.matchAll(reexportPattern)) {
      module.reexports.push({from: resolve(file, specifier), names: list === undefined ? '*' : names(list)});
    }
    for (const [, , name] of code.matchAll(declarationPattern)) module.declared.push(name);
    if (/^export\s*(default|\{[^}]*\}\s*;)/m.test(code) || /^import\s+(?!\{)/m.test(code)) {
      throw new Error(`${file}: unsupported module syntax`);
    }
    for (const edge of [...module.imports, ...module.reexports]) visit(edge.from);
  };
  entries.forEach(visit);
  // Type-only names vanish at run time: keep the names a module provides,
  // and of its imports only those its stripped code still mentions.
  const provided = file => {
    const module = modules.get(file);
    if (module.provided) return module.provided;
    module.provided = new Set(module.declared);
    for (const edge of module.reexports) {
      if (edge.names === '*') edge.names = [...provided(edge.from)].map(name => ({name, alias: name}));
      for (const {name, alias} of edge.names) if (provided(edge.from).has(name)) module.provided.add(alias);
    }
    return module.provided;
  };
  for (const module of modules.values()) {
    provided(module.file);
    const body = module.code.replace(importPattern, '').replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, '');
    for (const edge of module.reexports) edge.names = edge.names.filter(({name}) => provided(edge.from).has(name));
    for (const edge of module.imports) {
      edge.names = edge.names.filter(({name, alias}) =>
        provided(edge.from).has(name) && new RegExp(`(?<![\\w$.])${alias.replace('$', '\\$')}(?![\\w$])`).test(body));
    }
  }
  return modules;
}

function identifier(file) { return 'm_' + file.replace(/\.ts$/, '').replace(/[^\w]/g, '_'); }

// The modules in dependency order, each a function scope returning its
// exports; the region's value is the union of them.
function bundle(entries) {
  const modules = load(entries), order = [], state = new Map();
  const place = file => {
    if (state.get(file) === 'done') return;
    if (state.get(file) === 'active') throw new Error(`uwasi: run-time import cycle through ${file}`);
    state.set(file, 'active');
    const module = modules.get(file);
    for (const edge of [...module.imports, ...module.reexports]) if (edge.names.length) place(edge.from);
    state.set(file, 'done');
    order.push(module);
  };
  [...modules.keys()].forEach(place);
  const all = new Map(), lines = [];
  for (const module of order) {
    let code = module.code.replace(importPattern, '').replace(reexportPattern, '')
      .replace(declarationPattern, '$1$2');
    const bindings = module.imports.filter(edge => edge.names.length).map(edge =>
      `const {${edge.names.map(({name, alias}) => name === alias ? name : `${name}: ${alias}`).join(', ')}} = ` +
      `${identifier(edge.from)};`);
    const exported = [...module.declared, ...module.reexports.flatMap(edge => edge.names.map(({alias}) => alias))];
    for (const name of exported) {
      if (all.has(name) && all.get(name) !== module.file && !module.reexports.some(edge =>
        edge.names.some(({alias}) => alias === name))) {
        throw new Error(`uwasi: ${name} is exported by ${all.get(name)} and ${module.file}`);
      }
      if (!all.has(name)) all.set(name, module.file);
    }
    const reexported = module.reexports.flatMap(edge =>
      edge.names.map(({name, alias}) => `${alias}: ${identifier(edge.from)}.${name}`));
    code = code.split('\n').map(line => line.trimEnd()).join('\n').replace(/\n{3,}/g, '\n\n').trim();
    lines.push(`// vendor/uwasi/src/${module.file}`, `const ${identifier(module.file)} = (() => {`,
      ...bindings, code, `return {${[...module.declared, ...reexported].join(', ')}};`, '})();');
  }
  const union = [...all].map(([name, file]) => `${name}: ${identifier(file)}.${name}`);
  const text = ['const uwasi = (() => {', ...lines, `return {${union.join(', ')}};`, '})();'].join('\n');
  const declaration = /^\s*(import|export)\s.*$/m.exec(text);
  if (declaration) throw new Error(`uwasi: a bundle line reads as a module declaration: ${declaration[0]}`);
  return text;
}

function region(text, name, body, file) {
  const begin = `// ${name}: begin generated by scripts/build_uwasi_bundle.mjs; do not edit\n`;
  const end = `// ${name}: end generated\n`;
  const from = text.indexOf(begin), to = text.indexOf(end);
  if (from < 0 || to < from) throw new Error(`${file}: missing ${name} markers`);
  return text.slice(0, from + begin.length) + body + '\n' + text.slice(to);
}

function authored(text, name, file) {
  const begin = `// ${name}: begin\n`, end = `// ${name}: end\n`;
  const from = text.indexOf(begin), to = text.indexOf(end);
  if (from < 0 || to < from) throw new Error(`${file}: missing ${name} markers`);
  return text.slice(from + begin.length, to).trimEnd();
}

const header = `// uwasi ${UPSTREAM} (Apache-2.0, LICENSES/uwasi-LICENSE) with Titan's seams; see vendor/uwasi/UPSTREAM.md.\n`;
const core = ['filesystem/index.ts'];
const vfsFile = join(browser, 'titan-browser-vfs.mjs'), workerFile = join(browser, 'titan-storage-worker.mjs');
const vfs = readFileSync(vfsFile, 'utf8'), worker = readFileSync(workerFile, 'utf8');
const targets = [
  [vfsFile, vfs, region(vfs, 'uwasi', header + bundle(core), vfsFile)],
  [workerFile, worker, region(region(worker, 'uwasi', header + bundle([...core, 'opfs/index.ts']), workerFile),
    'storage core', authored(vfs, 'storage core', vfsFile), workerFile)],
];
let stale = false;
for (const [file, before, after] of targets) {
  if (before === after) continue;
  stale = true;
  if (process.argv.includes('--check')) console.error(`${relative(root, file)} is out of date; run node scripts/build_uwasi_bundle.mjs`);
  else writeFileSync(file, after);
}
if (stale && process.argv.includes('--check')) process.exit(1);
