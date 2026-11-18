// The module check of a browser image. titanc runs it once per link, under
// emcc's configured Node and with the acorn parser of emcc's installation:
//
//     node titan-browser-module-check.mjs <acorn.mjs> <module.mjs>
//
// It exits 0 for a module that loads no other module, and otherwise prints one
// refusal naming the construct and the route and exits 2. It keeps generated
// and EM_JS code to the deployment profile; it is not a sandbox for code
// written to evade it.
// Implementation notes: doc/implementation/browser-target.md#the-module-check
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [acornFile, moduleFile] = process.argv.slice(2);
const { parse } = await import(pathToFileURL(acornFile).href);
const text = readFileSync(moduleFile, "utf8");
const bridge = "pass page JavaScript to Titan as create({bindings}) values through titan.browser";
const selfContained = "the image module is self-contained; " + bridge;
const noNode = "browser images load no Node module; " + bridge;
// The Node built-ins that the Emscripten shell reads after titanc rewrites it.
const builtins = new Set(["fs", "path", "url"]);

function refuse(message) {
    process.stdout.write(`browser image module ${message}\n`);
    process.exit(2);
}

function refuseAt(node, construct, route) {
    const excerpt = text.slice(node.start, Math.min(node.end, node.start + 60)).replace(/\s+/g, " ");
    refuse(`${construct} at line ${node.loc.start.line} (${excerpt}); ${route}`);
}

let program;
try {
    program = parse(text, { ecmaVersion: "latest", sourceType: "module", locations: true });
} catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    refuse(`does not parse as an ES module: ${error.message}`);
}

// Whether an Identifier at parent[key] refers to a binding: property names,
// labels and meta-properties name nothing in scope.
function reference(parent, key) {
    switch (parent.type) {
    case "MemberExpression": case "Property": case "MethodDefinition": case "PropertyDefinition":
        return (key !== "property" && key !== "key") || parent.computed;
    case "LabeledStatement": case "BreakStatement": case "ContinueStatement": case "MetaProperty":
        return false;
    case "ExportSpecifier":
        return key === "local";
    default:
        return true;
    }
}

// The name that a member access or destructuring property reads.
function propertyName(node, name) {
    if (!node.computed) return name.name;
    if (name.type === "Literal") return name.value;
    if (name.type === "TemplateLiteral" && name.expressions.length === 0) return name.quasis[0].value.cooked;
    return null;
}

function readProperty(node, name, parent) {
    if (name === "require") refuseAt(node, "reads require", noNode);
    if (name !== "getBuiltinModule") return;
    const call = parent.type === "CallExpression" && parent.callee === node ? parent : null;
    const [argument, extra] = call ? call.arguments : [];
    if (!argument || extra || argument.type !== "Literal" || !builtins.has(argument.value)) {
        refuseAt(call || node, 'uses getBuiltinModule beyond the shell\'s "fs", "path" and "url" calls', noNode);
    }
}

// An explicit stack: generated code nests deeper than the call stack allows.
const pending = [[program, null, null]];
while (pending.length > 0) {
    const [node, parent, key] = pending.pop();
    switch (node.type) {
    case "ImportDeclaration":
        refuseAt(node, `imports ${JSON.stringify(node.source.value)}`, selfContained);
        break;
    case "ExportAllDeclaration": case "ExportNamedDeclaration":
        if (node.source) refuseAt(node, `re-exports from ${JSON.stringify(node.source.value)}`, selfContained);
        break;
    case "ImportExpression":
        refuseAt(node, "uses dynamic import()", selfContained);
        break;
    case "Identifier":
        if ((node.name === "require" || node.name === "getBuiltinModule") && reference(parent, key)) {
            refuseAt(node, `uses ${node.name}`, noNode);
        }
        break;
    case "MemberExpression":
        readProperty(node, propertyName(node, node.property), parent);
        break;
    case "Property":
        if (parent.type === "ObjectPattern") readProperty(node, propertyName(node, node.key), parent);
        break;
    }
    const children = [];
    for (const field in node) {
        const value = node[field];
        if (Array.isArray(value)) {
            for (const child of value) if (child) children.push([child, node, field]);
        } else if (value && typeof value.type === "string") {
            children.push([value, node, field]);
        }
    }
    // Popped in source order, so the first construct is the one reported.
    for (let index = children.length - 1; index >= 0; --index) pending.push(children[index]);
}
