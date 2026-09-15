//go:build ios

package quic

// Inside a Network Extension, recvmsg_x on an unconnected UDP socket delivers no data.
const msgxRequiresConnectedSocket = true
