export async function run(context) {
  context.stdout(new TextEncoder().encode('Playwright timeout entered\n'));
  await new Promise(() => {});
}
