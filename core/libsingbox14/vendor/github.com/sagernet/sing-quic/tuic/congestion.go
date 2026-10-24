package tuic

import (
	"context"
	"time"

	"github.com/sagernet/quic-go"
	congestion_meta1 "github.com/sagernet/sing-quic/congestion_meta1"
	congestion_meta2 "github.com/sagernet/sing-quic/congestion_meta2"
	"github.com/sagernet/sing/common/ntp"
)

func setCongestion(ctx context.Context, connection *quic.Conn, congestionName string) {
	timeFunc := ntp.TimeFuncFromContext(ctx)
	if timeFunc == nil {
		timeFunc = time.Now
	}
	initialPacketSize := connection.InitialPacketSize()
	switch congestionName {
	case "cubic":
		connection.SetCongestionControl(
			congestion_meta1.NewCubicSender(
				congestion_meta1.DefaultClock{TimeFunc: timeFunc},
				initialPacketSize,
				false,
			),
		)
	case "new_reno":
		connection.SetCongestionControl(
			congestion_meta1.NewCubicSender(
				congestion_meta1.DefaultClock{TimeFunc: timeFunc},
				initialPacketSize,
				true,
			),
		)
	case "bbr":
		connection.SetCongestionControl(congestion_meta2.NewBbrSenderWithProfile(initialPacketSize, congestion_meta2.ProfileStandard))
	}
}
