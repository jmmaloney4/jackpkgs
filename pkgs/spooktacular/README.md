# spooktacular

macOS virtual machine manager using Apple's Virtualization.framework.
Provides the `spook` CLI for creating, starting, and managing macOS VMs on Apple Silicon.

## Usage

```bash
# List VMs
spook list

# Create a VM from the latest IPSW
spook create my-vm --cpu 4 --memory 8 --disk 64 --from-ipsw latest

# Start with a display (for initial setup)
spook start my-vm

# Start headless (for production)
spook start my-vm --headless

# Get VM IP address
spook ip my-vm
```

## Troubleshooting

### IPSW catalog fetch fails (`--from-ipsw latest`)

If `spook create --from-ipsw latest` or `spook doctor` reports:

```
The restore image catalog failed to load. Installation service returned an unexpected error.
```

Apple's restore image catalog API (`gdmf.apple.com`) is unavailable. This is an Apple
server-side issue — transient outage, rate limiting, or API changes on new macOS versions.

**Workaround:** Download the IPSW manually and pass the local file path:

```bash
# 1. Find the latest IPSW URL from ipsw.me (replace Mac14,7 with your model identifier)
curl -s "https://api.ipsw.me/v4/device/Mac14,7?type=ipsw" | python3 -m json.tool

# 2. Download it (~18-20 GB)
curl -L -o /tmp/macos-restore.ipsw "<url from step 1>"

# 3. Create VM from local file
spook create my-vm --cpu 4 --memory 8 --disk 64 --from-ipsw /tmp/macos-restore.ipsw
```

This bypasses the catalog lookup entirely — same IPSW file, direct from Apple's CDN.

