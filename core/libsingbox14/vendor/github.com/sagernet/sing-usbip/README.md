# sing-usbip

Cross-platform USB/IP implementation in Go

Backends:

| Platform | Server (export)                  | Client (import)                       |
|----------|----------------------------------|---------------------------------------|
| Linux    | `usbip-host` kernel driver       | `vhci_hcd` kernel driver              |
| macOS    | IOUSBHost (disable SIP required) | IOUSBHostControllerInterface          |
| Windows  | VBoxUSB drivers (bundled)        | usbip-win2 UDE vhci driver (bundled)  |

The Windows drivers are embedded in the binary by default. Builds with the
`with_external_usbip_drivers` tag instead load them from the executable
directory, verified against the digests in `driverassets`; regenerate the
digests with `go generate ./driverassets` after replacing driver files.

## Control extension

Standard USB/IP has no change notifications, so importers must poll for
device arrivals and removals. sing-usbip adds a control channel that pushes
device state to the client instead. It runs on its own connections alongside
the standard protocol, so the server keeps serving standard usbip clients
unchanged; the sing-usbip client always imports through the extension and
requires a sing-usbip server.

## CLI

Export devices (matched by busid, vendor:product, and/or serial):

```
sing-usbip list
sing-usbip run -s :3240 -d 1-1.2
sing-usbip run -s 127.0.0.1:3240 -d 0bda:8153,serial=001000001
```

Import devices (without `--device`, every exported device is imported):

```
sing-usbip list -c 192.168.1.10
sing-usbip run -c 192.168.1.10 -d 0bda:8153
```

Exported devices can also be attached by standard usbip clients; importing
requires a sing-usbip server.
