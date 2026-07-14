# Fixture: ADR directory with filenames containing spaces

This fixture validates that the ADR conflict checker correctly handles
filenames with spaces in their names. Files should be stored with spaces
included (e.g., "001-with space.md"), not with underscores or hyphens
as substitutes.

## Expected behavior

- The script should correctly detect duplicates even when filenames contain spaces
- Newline separators in the associative array values prevent false positives
- Counting uses `wc -l` not `wc -w`
- Display output replaces newlines with spaces for readability
