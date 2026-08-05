# GNU Readline fallback patches

Titan's prefix-local fallback starts from GNU Readline 8.3 and applies the
first three official upstream patches. The build downloads and verifies the
base release archive; the small combined unified patch is kept here so an
immutable host does not also need a system `patch` utility.

Upstream artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `readline-8.3.tar.gz` | `fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc` |
| `readline83-001` | `21f0a03106dbe697337cd25c70eb0edbaa2bdb6d595b45f83285cdd35bac84de` |
| `readline83-002` | `e27364396ba9f6debf7cbaaf1a669e2b2854241ae07f7eca74ca8a8ba0c97472` |
| `readline83-003` | `72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29` |
| `readline-8.3-p1-p3.patch` (format-only combination) | `70cbc596c0a7b3a35fabb8a05711a60e2695bd2d06a4e2f46f6f168f84403f96` |

The base archive's `COPYING` is unchanged by those patches and has SHA-256
`8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903`.
Its exact text is checked in as `LICENSES/readline-LICENSE`; the bundled build
also installs that text at
`$PREFIX/lib/titan/deps/readline/8.3-p3/share/licenses/COPYING`.

The release archive is from
<https://ftp.gnu.org/gnu/readline/readline-8.3.tar.gz>. The original context
diffs are from
<https://ftp.gnu.org/gnu/readline/readline-8.3-patches/>. The file
`readline-8.3-p1-p3.patch` is a format-only combination of those three diffs;
it makes the same changes and advances upstream's `patchlevel` file to `3`.
