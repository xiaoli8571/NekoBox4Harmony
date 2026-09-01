import router from '@ohos.router';
import { t, isEnglish } from '../utils/I18n';

interface ToolEntry {
  key: string;
  desc: string;
  descEn: string;
  url: string;
}

/** 设置页"工具"入口的枢纽页:汇集暂未放上主页的只读工具页面。 */
const TOOLS: Array<ToolEntry> = [
  {
    key: 'traffic',
    desc: '实时速率、会话流量与累计用量',
    descEn: 'Live speed, per-connection and total usage',
    url: 'pages/TrafficPage'
  },
  {
    key: 'diagnostics',
    desc: '只读体检报告,便于远程排障',
    descEn: 'Read-only health report for remote troubleshooting',
    url: 'pages/DiagnosticsPage'
  },
  {
    key: 'appList',
    desc: '按包名排除或指定走代理的应用',
    descEn: 'Exclude or select apps by package name',
    url: 'pages/AppList'
  }
];

@Entry
@Component
struct ToolsPage {
  build(): void {
    Column({ space: 10 }) {
      Row() {
        Text('←').fontSize(22).fontColor('#333333').onClick(() => router.back()).padding(8)
        Text(t('tools')).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#333333').layoutWeight(1)
      }.width('100%').padding(12)

      Column({ space: 10 }) {
        ForEach(TOOLS, (item: ToolEntry) => {
          Row() {
            Column({ space: 3 }) {
              Text(t(item.key)).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#333333')
              Text(isEnglish() ? item.descEn : item.desc).fontSize(12).fontColor('#888888')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text('›').fontSize(20).fontColor('#BBBBBB')
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .onClick(() => router.pushUrl({ url: item.url }))
        }, (item: ToolEntry) => item.url)
      }.width('100%')

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#F2F4F7')
  }
}
