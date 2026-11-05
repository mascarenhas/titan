// The runner test supplies a compiler-produced image whose map was omitted.
// Exercise context.image's policy, not a synthetic second image lifecycle.
export async function run(context) {
    context.assert(context.args.length > 0, 'pass the real image with a missing map');
    const {create, locateFile} = await context.image(context.args[0]);
    const instance = create({locateFile, stdout: context.stdout, stderr: context.stderr});
    try {
        const result = await instance.run(context.args.slice(1));
        context.assert(result.kind === 'returned' && result.status === 0,
            new TextDecoder().decode(result.bytes));
    } finally { await instance.dispose(); }
}
