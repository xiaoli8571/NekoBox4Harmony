import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { Profile, ProfileType, profileTypeLabel, supportsTransport, needsTlsByDefault } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles } from '../model/Store';
import { getClipboardText } from '../utils/ClipboardHelper';
import { parseSingleLink, parseShareText } from '../utils/LinkParser';

const ALL_TYPES: Array<string> = [
  ProfileType.SHADOWSOCKS, ProfileType.VMESS, ProfileType.VLESS, ProfileType.TROJAN,
  ProfileType.HYSTERIA, ProfileType.HYSTERIA2, ProfileType.TUIC, ProfileType.WIREGUARD,
  ProfileType.HTTP, ProfileType.SOCKS
];
const TRANSPORTS: Array<string> = ['', 'ws', 'grpc', 'http', 'httpupgrade', 'quic'];

@Entry
@Component
struct ProfileEdit {
  @State p: Profile = new Profile();
  @State isNew: boolean = true;
  @State pasteText: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    const id: string = AppStorage.get<string>('editProfileId') ?? '';
    initStore(this.context).then(async () => {
      const profiles = await loadProfiles();
      const found = profiles.find(x => x.id === id);
      if (found !== undefined) {
        this.p = found;
        this.isNew = false;
      } else {
        this.p = new Profile();
        this.p.id = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
        this.isNew = true;
      }
    });
  }

  validationError(): string {
    if (this.p.server.trim().length === 0) {
      return '服务器地址不能为空';
    }
    if (!Number.isInteger(this.p.serverPort) || this.p.serverPort < 1 || this.p.serverPort > 65535) {
      return '端口必须是 1 到 65535 之间的整数';
    }
    const uuidRequired = this.p.type === ProfileType.VMESS || this.p.type === ProfileType.VLESS
      || this.p.type === ProfileType.TUIC;
    if (uuidRequired && !/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/.test(this.p.uuid.trim())) {
      return '请输入有效的 UUID';
    }
    if (this.p.type === ProfileType.SHADOWSOCKS) {
      if (this.p.method.trim().length === 0) {
        return 'Shadowsocks 加密方式不能为空';
      }
      if (this.p.password.length === 0) {
        return 'Shadowsocks 密码不能为空';
      }
    }
    if ((this.p.type === ProfileType.TROJAN || this.p.type === ProfileType.HYSTERIA
      || this.p.type === ProfileType.HYSTERIA2) && this.p.password.length === 0) {
      return '认证密码不能为空';
    }
    if (this.p.type === ProfileType.TUIC && this.p.password.length === 0) {
      return 'TUIC 密码不能为空';
    }
    if (this.p.realityPublicKey.length > 0
      && !/^[A-Za-z0-9_-]{32,64}$/.test(this.p.realityPublicKey.trim())) {
      return 'REALITY 公钥格式不正确';
    }
    if (this.p.realityShortId.length > 0
      && !/^[0-9a-fA-F]{2,16}$/.test(this.p.realityShortId.trim())) {
      return 'REALITY short_id 必须是 2 到 16 位十六进制字符';
    }
    if (this.p.extra.trim().length > 0) {
      try {
        JSON.parse(this.p.extra);
      } catch (e) {
        return '附加 JSON 格式不正确';
      }
    }
    return '';
  }

  async save(): Promise<void> {
    const validationError = this.validationError();
    if (validationError.length > 0) {
      promptAction.showToast({ message: validationError });
      return;
    }
    if (this.p.name.trim().length === 0) {
      this.p.name = `${this.p.server.trim()}:${this.p.serverPort}`;
    }
    this.p.server = this.p.server.trim();
    try {
      await initStore(this.context);
      const profiles = await loadProfiles();
      const idx = profiles.findIndex(x => x.id === this.p.id);
      this.p.updatedAt = Date.now();
      if (idx >= 0) {
        profiles[idx] = this.p;
      } else {
        profiles.push(this.p);
      }
      await saveProfiles(profiles);
      promptAction.showToast({ message: '已保存' });
      router.back();
    } catch (e) {
      promptAction.showToast({ message: `保存失败: ${e}` });
    }
  }

  /** 把输入框内容解析成节点填入表单 */
  applyPasted(): void {
    const t = this.pasteText.trim();
    if (t.length === 0) {
      promptAction.showToast({ message: '请先粘贴链接内容' });
      return;
    }
    const firstLine = t.split(/[\r\n]+/)[0].trim();
    if (firstLine.startsWith('http://') || firstLine.startsWith('https://')) {
      promptAction.showToast({ message: '这是订阅链接,请回主页用「导入链接」' });
      return;
    }
    try {
      let p = parseSingleLink(firstLine);
      if (p === null) {
        const list = parseShareText(t);
        if (list.length > 0) {
          p = list[0];
        }
      }
      if (p === null) {
        promptAction.showToast({ message: '无法识别的节点链接,请检查内容' });
        return;
      }
      p.id = this.p.id;
      this.p = p;
      promptAction.showToast({ message: '已解析,请核对后保存' });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `解析失败: ${msg}` });
    }
  }

  async readClipboardIntoBox(): Promise<void> {
    const t = await getClipboardText();
    if (t.trim().length === 0) {
      promptAction.showToast({ message: '剪贴板为空,请手动粘贴' });
      return;
    }
    this.pasteText = t;
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text(this.isNew ? '新建节点' : '编辑节点')
          .fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('保存').height(34).onClick(() => this.save())
      }
      .width('100%').padding(12)

      Scroll() {
        Column({ space: 10 }) {
          // 快捷:手动粘贴节点链接解析(不依赖剪贴板权限)
          Column({ space: 6 }) {
            TextArea({
              text: this.pasteText,
              placeholder: '粘贴 vless:// vmess:// ss:// trojan:// 等节点链接(支持多条,取第一条)'
            })
              .height(88)
              .onChange((v: string) => {
                this.pasteText = v;
              })
            Row({ space: 8 }) {
              Button('从剪贴板读取')
                .backgroundColor('#F5F5F5')
                .fontColor('#333333')
                .onClick(() => this.readClipboardIntoBox())
              Blank()
              Button('解析并填入')
                .backgroundColor('#1565C0')
                .onClick(() => this.applyPasted())
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 协议类型
          Column() {
            Text('协议类型').fontSize(13).fontColor('#666')
            Select(ALL_TYPES.map((t: string) => ({ value: profileTypeLabel(t) } as SelectOption)))
              .selected(ALL_TYPES.indexOf(this.p.type))
              .value(profileTypeLabel(this.p.type))
              .onSelect((index: number) => {
                this.p.type = ALL_TYPES[index];
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          this.CommonFields()
          if (this.p.type === ProfileType.SHADOWSOCKS) {
            this.SsFields()
          }
          if (this.p.type === ProfileType.VMESS) {
            this.VmessFields()
          }
          if (this.p.type === ProfileType.VLESS) {
            this.VlessFields()
          }
          if (this.p.type === ProfileType.TROJAN) {
            this.PasswordFields('密码 (Trojan)')
          }
          if (this.p.type === ProfileType.HYSTERIA) {
            this.HysteriaFields()
          }
          if (this.p.type === ProfileType.HYSTERIA2) {
            this.Hysteria2Fields()
          }
          if (this.p.type === ProfileType.TUIC) {
            this.TuicFields()
          }
          if (this.p.type === ProfileType.WIREGUARD) {
            this.WireguardFields()
          }
          if (this.p.type === ProfileType.HTTP || this.p.type === ProfileType.SOCKS) {
            this.UserPassFields()
          }
          if (supportsTransport(this.p.type)) {
            this.TransportFields()
          }
          if (this.p.tls || needsTlsByDefault(this.p.type) || this.p.realityPublicKey.length > 0) {
            this.TlsFields()
          }
          this.AdvancedFields()
        }
        .width('100%')
        .padding(12)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor('#F2F4F7')
  }

  @Builder
  Field(label: string, placeholder: string, val: string, onChange: (v: string) => void, inputType: InputType = InputType.Normal) {
    Column() {
      Text(label).fontSize(13).fontColor('#666').width('100%')
      TextInput({ text: val, placeholder: placeholder })
        .type(inputType)
        .width('100%')
        .height(40)
        .onChange(onChange)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder
  CommonFields() {
    Column({ space: 10 }) {
      this.Field('名称', '节点名称', this.p.name, (v: string) => { this.p.name = v; })
      this.Field('服务器地址', 'domain or IP', this.p.server, (v: string) => { this.p.server = v; })
      this.Field('端口', '443', `${this.p.serverPort === 0 ? '' : this.p.serverPort}`,
        (v: string) => { this.p.serverPort = parseInt(v.length > 0 ? v : '0'); }, InputType.Number)
    }
  }

  @Builder
  SsFields() {
    Column({ space: 10 }) {
      this.Field('加密方式', 'aes-128-gcm / chacha20-ietf-poly1305 / 2022-*', this.p.method,
        (v: string) => { this.p.method = v; })
      this.Field('密码', 'password', this.p.password, (v: string) => { this.p.password = v; })
    }
  }

  @Builder
  VmessFields() {
    Column({ space: 10 }) {
      this.Field('UUID', 'uuid', this.p.uuid, (v: string) => { this.p.uuid = v; })
      this.Field('alterId', '0', `${this.p.alterId}`, (v: string) => { this.p.alterId = parseInt(v.length > 0 ? v : '0'); },
        InputType.Number)
      this.Field('加密 (security)', 'auto', this.p.security, (v: string) => { this.p.security = v; })
    }
  }

  @Builder
  VlessFields() {
    Column({ space: 10 }) {
      this.Field('UUID', 'uuid', this.p.uuid, (v: string) => { this.p.uuid = v; })
      this.Field('Flow', '留空 / xtls-rprx-vision', this.p.flow, (v: string) => { this.p.flow = v; })
    }
  }

  @Builder
  PasswordFields(label: string) {
    this.Field(label, 'password', this.p.password, (v: string) => { this.p.password = v; })
  }

  @Builder
  HysteriaFields() {
    Column({ space: 10 }) {
      this.Field('认证字符串 (auth_str)', 'auth', this.p.password, (v: string) => { this.p.password = v; })
      this.Field('上行 Mbps', '100', `${this.p.upMbps}`, (v: string) => { this.p.upMbps = parseInt(v.length > 0 ? v : '0'); },
        InputType.Number)
      this.Field('下行 Mbps', '100', `${this.p.downMbps}`, (v: string) => { this.p.downMbps = parseInt(v.length > 0 ? v : '0'); },
        InputType.Number)
      this.Field('obfs (Salamander)', '留空 / 密码', this.p.obfs, (v: string) => { this.p.obfs = v; })
    }
  }

  @Builder
  Hysteria2Fields() {
    Column({ space: 10 }) {
      this.PasswordFields('密码 (Hysteria2)')
      this.Field('上行 Mbps (可空)', '100', ``, (v: string) => { this.p.upMbps = parseInt(v.length > 0 ? v : '0'); }, InputType.Number)
      this.Field('下行 Mbps (可空)', '100', ``, (v: string) => { this.p.downMbps = parseInt(v.length > 0 ? v : '0'); }, InputType.Number)
      this.Field('obfs 混淆密码 (可空)', 'salamander 密码', this.p.obfs, (v: string) => { this.p.obfs = v; })
    }
  }

  @Builder
  TuicFields() {
    Column({ space: 10 }) {
      this.Field('UUID', 'uuid', this.p.uuid, (v: string) => { this.p.uuid = v; })
      this.Field('密码', 'password (可空)', this.p.password, (v: string) => { this.p.password = v; })
      this.Field('拥塞控制', 'bbr / cubic / new_reno', this.p.congestionControl, (v: string) => { this.p.congestionControl = v; })
      this.Field('UDP 中继模式', 'native / quic', this.p.udpRelayMode, (v: string) => { this.p.udpRelayMode = v; })
    }
  }

  @Builder
  WireguardFields() {
    Column({ space: 10 }) {
      this.Field('本地地址 (CIDR)', '172.16.0.2/32', this.p.localAddress, (v: string) => { this.p.localAddress = v; })
      this.Field('本机私钥 (private_key)', '', this.p.privateKey, (v: string) => { this.p.privateKey = v; })
      this.Field('对端公钥 (peer public_key)', '', this.p.peerPublicKey, (v: string) => { this.p.peerPublicKey = v; })
      this.Field('预共享密钥 (可选)', '', this.p.preSharedKey, (v: string) => { this.p.preSharedKey = v; })
    }
  }

  @Builder
  UserPassFields() {
    Column({ space: 10 }) {
      this.Field('用户名 (可选)', 'username', this.p.username, (v: string) => { this.p.username = v; })
      this.Field('密码 (可选)', 'password', this.p.password, (v: string) => { this.p.password = v; })
    }
  }

  @Builder
  TransportFields() {
    Column() {
      Text('传输层').fontSize(13).fontColor('#666').width('100%')
      Select(TRANSPORTS.map((t: string) => ({ value: t === '' ? 'TCP (无)' : t } as SelectOption)))
        .selected(TRANSPORTS.indexOf(this.p.transport) < 0 ? 0 : TRANSPORTS.indexOf(this.p.transport))
        .value(this.p.transport === '' ? 'TCP (无)' : this.p.transport)
        .onSelect((index: number) => { this.p.transport = TRANSPORTS[index]; })
      if (this.p.transport === 'ws' || this.p.transport === 'http' || this.p.transport === 'httpupgrade') {
        this.Field('Path', '/', this.p.path, (v: string) => { this.p.path = v; })
        this.Field('Host', '域名', this.p.host, (v: string) => { this.p.host = v; })
      }
      if (this.p.transport === 'grpc') {
        this.Field('serviceName', '', this.p.serviceName, (v: string) => { this.p.serviceName = v; })
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder
  TlsFields() {
    Column({ space: 10 }) {
      Row() {
        Text('启用 TLS').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.p.tls })
          .onChange((v: boolean) => { this.p.tls = v; })
      }.width('100%')

      this.Field('SNI', '留空则使用服务器地址', this.p.sni, (v: string) => { this.p.sni = v; })
      this.Field('ALPN (逗号分隔)', 'h2,http/1.1 或 h3', this.p.alpn, (v: string) => { this.p.alpn = v; })
      this.Field('uTLS 指纹 (fp, 留空默认)', 'chrome / firefox / safari / ios…', this.p.fingerprint, (v: string) => { this.p.fingerprint = v; })
      this.Field('REALITY 公钥 (pbk, 可选)', '', this.p.realityPublicKey, (v: string) => { this.p.realityPublicKey = v; })
      this.Field('REALITY short_id (可选)', '', this.p.realityShortId, (v: string) => { this.p.realityShortId = v; })

      Row() {
        Text('允许不安全 TLS (insecure)').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.p.allowInsecure })
          .onChange((v: boolean) => { this.p.allowInsecure = v; })
      }.width('100%')

      Row() {
        Text('多路复用 (mux)').fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.p.mux })
          .onChange((v: boolean) => { this.p.mux = v; })
      }.width('100%')
    }
  }

  @Builder
  AdvancedFields() {
    Column({ space: 10 }) {
      this.Field('附加 JSON (高级, 与出站对象合并)', '{"dialer":{}}', this.p.extra,
        (v: string) => { this.p.extra = v; })
      Text('长按主页节点可删除;支持从剪贴板导入 ss/vmess/vless/trojan/hysteria/tuic 链接与 base64 订阅')
        .fontSize(11).fontColor('#999').width('100%')
    }
  }
}
