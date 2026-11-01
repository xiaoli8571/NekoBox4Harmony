import { formatSpeed } from '../../utils/TrafficStats';
import { UiSpec } from '../UiSpec';
import { pressLightEffect } from '../Effects';

/**
 * 底部速率条(P1 从 Index 抽出)。
 *
 * 为什么单独成组件:流量由 :vpn 扩展每秒推送一次(`vpnUpSpeed/vpnDownSpeed` 写
 * AppStorage)。以前这两个键是 Index 的 @StorageLink,1s 一次会把整个 4700 行的
 * 首页重建一遍;抽出来后只有这条 44vp 的组件跟着刷新。
 *
 * 观感定稿(2026-10-23 用户实测):半透明底色 + `backdropBlur(20)`。
 * ⚠️ 不要改用 `backgroundBlurStyle(BlurStyle.COMPONENT_*)`:组件材质自带近乎不
 * 透明的填充,会把半透明底色吃掉 ⇒ 真机观感"完全不透"。
 */
@Component
export struct StatsBar {
  @StorageLink('vpnUpSpeed') upSpeed: number = 0;
  @StorageLink('vpnDownSpeed') downSpeed: number = 0;
  @StorageLink('vpnRunning') isRunning: boolean = false;
  @StorageLink('vpnStatus') statusText: string = 'disconnected';
  @State private pressed: boolean = false;
  /** 整条可点:连接中测当前节点(对齐安卓 StatsBar.kt/BaseService.kt 的 status 点击) */
  onTap: () => void = (): void => {
  };

  /** VPN 状态 token → 本地化文案(词表与 VpnIpc/EntryAbility 一致) */
  private statusDisplay(): ResourceStr {
    const s = this.statusText;
    if (s === 'connecting') {
      return $r('app.string.status_connecting');
    }
    if (s === 'disconnecting') {
      return $r('app.string.status_disconnecting');
    }
    if (s === 'disconnected') {
      return $r('app.string.status_disconnected');
    }
    if (s === 'switching') {
      return $r('app.string.status_switching');
    }
    if (s === 'start_timeout') {
      return $r('app.string.status_start_timeout');
    }
    if (s === 'awaiting_auth') {
      return $r('app.string.status_awaiting_auth');
    }
    if (s.startsWith('connected:')) {
      return $r('app.string.status_connected_node', s.substring('connected:'.length));
    }
    if (s.startsWith('start_failed:')) {
      return $r('app.string.status_start_failed', s.substring('start_failed:'.length));
    }
    if (s.startsWith('connect_failed:')) {
      return $r('app.string.status_connect_failed', s.substring('connect_failed:'.length));
    }
    return s;
  }

  build() {
    Row({ space: 12 }) {
      Text(`↑ ${formatSpeed(this.upSpeed)}`)
        .fontSize(12).fontColor($r('app.color.text_2'))
        .fontFamily('monospace')
      Text(`↓ ${formatSpeed(this.downSpeed)}`)
        .fontSize(12).fontColor($r('app.color.text_2'))
        .fontFamily('monospace')
      Row({ space: 6 }) {
        Circle()
          .width(7).height(7)
          .fill(this.isRunning ? $r('app.color.dot_live') : $r('app.color.text_3'))
        Text(this.statusDisplay())
          .fontSize(12).fontColor($r('app.color.text_2'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height(44)
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
    .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
    /* 节点列表挂着 .clip(false),滚动时卡片会画到本条底部边界之外 ⇒ 无背景时
       速率文字和列表文字直接重叠。底色由资源控制不透明度(#B8 ≈ 72%),深浅色各一份。 */
    .backdropBlur(20)
    .backgroundColor($r('app.color.statsbar_bg'))
    .visualEffect(pressLightEffect(this.pressed, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up) {
        this.pressed = false;
        this.onTap();
      } else if (event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}
