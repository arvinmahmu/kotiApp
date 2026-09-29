/**
 * A test harness small enough to read in one sitting.
 *
 * Deliberately not a framework: these files run with plain `node` (Node 24
 * strips the types), so the pure domain logic can be verified with no install,
 * no Deno, no database and no account.
 */
let passed = 0;

export function test(name: string, fn: () => void): void {
  try {
    fn();
    passed++;
    console.log(`  ok   ${name}`);
  } catch (err) {
    console.error(`  FAIL ${name}`);
    console.error(`       ${(err as Error).message}`);
    process.exitCode = 1;
  }
}

export function report(): void {
  console.log("");
  console.log(`${passed} assertions passed`);
  console.log("");
}
