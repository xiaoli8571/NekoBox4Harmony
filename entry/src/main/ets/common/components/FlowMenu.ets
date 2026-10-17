import { ComponentContent, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 沉浸光感菜单（照 RzdSchool `CommonUi.ets:129-200` 的成熟实现，用户点名"参考 RzdSchool 加上沉浸光感"）。
 *
 * 为什么不用 `bindMenu`：`bindMenu` 的背板只能用默认系统材质，做不出"跟着背后画面走"的光感。
 * 这里的四件套缺一不可：
 *   ① `UIContext.getPromptAction().openMenu(node, { id: anchorId }, options)` —— 系统菜单窗口 + 自绘内容，
 *      `anchorId` 必须对应某个真实组件上的 `.id(...)`；
 *   ② `backgroundBlurStyle`（按"光感强度"给档位）——背板模糊；
 *   ③ **`backgroundBlurStyleOptions: { adaptiveColor: AdaptiveColor.AVERAGE }`** —— "光感随背后画面走"
 *      （默认 `DEFAULT` 是固定色蒙版，这就是"菜单没有光感"的真正原因）；
 *   ④ `placement: Placement.BottomRight` —— 锚点都在右侧，默认会把菜单铺到左边。
 *
 * ⚠️ API 版本边界：菜单容器的 systemMaterial/uiMaterial 是 API 26 能力，本工程（API 24）**一行都没用**；
 *    能用的是上面这套「系统菜单窗口 + 自绘面板 + 模糊背板 + 自适应取色」。
 */
export class MenuItemData {
  label: ResourceStr = '';
  value: string = '';
  selected: boolean = false;
}

export class SimpleMenuParam {
  items: MenuItemData[] = [];
  onPick: (index: number) => void = (index: number): void => {
  };
}

@Builder
export function simpleMenuPanel(param: SimpleMenuParam) {
  Column() {
    ForEach(param.items, (it: MenuItemData, index: number) => {
      Row({ space: 10 }) {
        Text(it.label)
          .fontSize(15)
          .fontColor(it.selected ? $r('app.color.primary') : $r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (it.selected) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(15)
            .fontColor([$r('app.color.primary')])
        }
      }
      .width('100%')
      .height(46)
      .padding({ left: 16, right: 16 })
      .onClick(() => {
        param.onPick(index);
      })
    }, (it: MenuItemData, index: number) => 'menu_item_' + index + '_' + it.label + '_' + it.selected)
  }
  .width(220)
  .padding({ top: 6, bottom: 6 })
}

/** 菜单背板模糊档（与顶栏光感"精致"同口径：厚一档，保证深色下也看得出材质） */
export function menuBlurStyle(): BlurStyle {
  return BlurStyle.COMPONENT_THICK;
}

export class HdsMenu {
  private node: ComponentContent<SimpleMenuParam> | undefined = undefined;
  private shown: boolean = false;
  private closing: boolean = false;

  open(ctx: UIContext, anchorId: string, items: MenuItemData[], onPick: (index: number) => void): void {
    if (items.length === 0) {
      return;
    }
    const param: SimpleMenuParam = new SimpleMenuParam();
    param.items = items;
    param.onPick = (index: number): void => {
      this.close(ctx);
      onPick(index);
    };
    const node: ComponentContent<SimpleMenuParam> =
      new ComponentContent(ctx, wrapBuilder(simpleMenuPanel), param);
    const options: MenuOptions = {
      mask: false,
      /* 显式贴锚点右缘弹出：锚点都在右上角，默认 placement 会把菜单铺到左边 */
      placement: Placement.BottomRight,
      backgroundBlurStyle: menuBlurStyle(),
      /* ★ 关键一行：光感随背后画面取色（默认 DEFAULT 是固定色蒙版 ⇒ "没有光感"） */
      backgroundBlurStyleOptions: { adaptiveColor: AdaptiveColor.AVERAGE },
      onWillDisappear: (): void => {
        this.node = undefined;
        this.shown = false;
        this.closing = false;
      },
      onDisappear: (): void => {
        this.node = undefined;
        this.shown = false;
        this.closing = false;
      }
    };
    this.node = node;
    this.shown = false;
    this.closing = false;
    ctx.getPromptAction().openMenu(node, { id: anchorId }, options)
      .then(() => {
        if (this.node === node && !this.closing) {
          this.shown = true;
        }
      })
      .catch((err: BusinessError) => {
        if (this.node === node) {
          this.node = undefined;
          this.shown = false;
        }
      });
  }

  /** 只对"确认已弹出"的节点发关闭：对未弹出的内容节点调 closeMenu 会报 103303 */
  close(ctx: UIContext): void {
    const node: ComponentContent<SimpleMenuParam> | undefined = this.node;
    if (node === undefined || !this.shown || this.closing) {
      this.node = undefined;
      this.shown = false;
      return;
    }
    this.closing = true;
    try {
      ctx.getPromptAction().closeMenu(node);
    } catch (e) {
      // 关闭失败不影响后续（节点已标记清空）
    }
    this.node = undefined;
    this.shown = false;
    this.closing = false;
  }
}
