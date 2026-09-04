import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import common from '@ohos.app.ability.common';
import { Profile, ProfileType, profileTypeLabel, supportsTransport, needsTlsByDefault } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, readPrefString } from '../model/Store';
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
  @StorageProp('statusBarHeightVp') statusBarVp: number = 0;
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
        // 新建节点默认带入最近使用的订阅分组(按名称匹配;无同名分组则保持未分组)
        const recentGroupName = await readPrefString('recent_subscription_group', '');
        if (recentGroupName.trim().length > 0) {
          const groups = await loadGroups();
          const matched = groups.find(g => g.name === recentGroupName.trim());
          if (matched !== undefined) {
            this.p.groupId = matched.id;
          }
        }
      }
    });
  }

  validationError(): ResourceStr {
    if (this.p.server.trim().length === 0) {
      return $r('app.string.error_server_required');
    }
    if (!Number.isInteger(this.p.serverPort) || this.p.serverPort < 1 || this.p.serverPort > 65535) {
      return $r('app.string.error_port_range');
    }
    const uuidRequired = this.p.type === ProfileType.VMESS || this.p.type === ProfileType.VLESS
      || this.p.type === ProfileType.TUIC;
    if (uuidRequired && !/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/.test(this.p.uuid.trim())) {
      return $r('app.string.error_invalid_uuid');
    }
    if (this.p.type === ProfileType.SHADOWSOCKS) {
      if (this.p.method.trim().length === 0) {
        return $r('app.string.error_ss_method_required');
      }
      if (this.p.password.length === 0) {
        return $r('app.string.error_ss_password_required');
      }
    }
    if ((this.p.type === ProfileType.TROJAN || this.p.type === ProfileType.HYSTERIA
      || this.p.type === ProfileType.HYSTERIA2) && this.p.password.length === 0) {
      return $r('app.string.error_auth_password_required');
    }
    if (this.p.type === ProfileType.TUIC && this.p.password.length === 0) {
      return $r('app.string.error_tuic_password_required');
    }
    if (this.p.realityPublicKey.length > 0
      && !/^[A-Za-z0-9_-]{32,64}$/.test(this.p.realityPublicKey.trim())) {
      return $r('app.string.error_reality_public_key');
    }
    if (this.p.realityShortId.length > 0
      && !/^[0-9a-fA-F]{2,16}$/.test(this.p.realityShortId.trim())) {
      return $r('app.string.error_reality_short_id');
    }
    if (this.p.extra.trim().length > 0) {
      try {
        JSON.parse(this.p.extra);
      } catch (e) {
        return $r('app.string.error_extra_json');
      }
    }
    return '';
  }

  async save(): Promise<void> {
    const validationError = this.validationError();
    if (validationError !== '') {
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
      promptAction.showToast({ message: $r('app.string.saved') });
      router.back();
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
    }
  }

  /** 把输入框内容解析成节点填入表单 */
  applyPasted(): void {
    const t = this.pasteText.trim();
    if (t.length === 0) {
      promptAction.showToast({ message: $r('app.string.paste_link_first') });
      return;
    }
    const firstLine = t.split(/[\r\n]+/)[0].trim();
    if (firstLine.startsWith('http://') || firstLine.startsWith('https://')) {
      promptAction.showToast({ message: $r('app.string.subscription_link_use_home') });
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
        promptAction.showToast({ message: $r('app.string.unrecognized_profile_link') });
        return;
      }
      p.id = this.p.id;
      this.p = p;
      promptAction.showToast({ message: $r('app.string.parsed_review_save') });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.parse_failed_reason', msg) });
    }
  }

  async readClipboardIntoBox(): Promise<void> {
    const t = await getClipboardText();
    if (t.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.clipboard_empty_paste_manually_short') });
      return;
    }
    this.pasteText = t;
  }

  build() {
    Column() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text(this.isNew ? $r('app.string.profile_new_title') : $r('app.string.profile_edit_title'))
          .fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.save')).height(34).onClick(() => this.save())
      }
      .width('100%').padding(12)

      Scroll() {
        Column({ space: 10 }) {
          // 快捷:手动粘贴节点链接解析(不依赖剪贴板权限)
          Column({ space: UiSpec.GAP_SM }) {
            TextArea({
              text: this.pasteText,
              placeholder: $r('app.string.profile_link_placeholder')
            })
              .height(88)
              .onChange((v: string) => {
                this.pasteText = v;
              })
            Row({ space: UiSpec.GAP_SM }) {
              Button($r('app.string.read_from_clipboard'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => this.readClipboardIntoBox())
              Button($r('app.string.parse_and_fill'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                .onClick(() => this.applyPasted())
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          // 协议类型
          Column() {
            Text($r('app.string.protocol_type')).fontSize(13).fontColor($r('app.color.text_secondary'))
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
            this.PasswordFields($r('app.string.password_trojan'))
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
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: UiSpec.GAP_MD, bottom: UiSpec.GAP_MD })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
    .padding({ top: this.statusBarVp })
  }

  @Builder
  Field(label: ResourceStr, placeholder: ResourceStr, val: string, onChange: (v: string) => void, inputType: InputType = InputType.Normal) {
    Column() {
      Text(label).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
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
      this.Field($r('app.string.profile_name'), $r('app.string.profile_name_placeholder'), this.p.name, (v: string) => { this.p.name = v; })
      this.Field($r('app.string.server_address'), 'domain or IP', this.p.server, (v: string) => { this.p.server = v; })
      this.Field($r('app.string.port'), '443', `${this.p.serverPort === 0 ? '' : this.p.serverPort}`,
        (v: string) => { this.p.serverPort = parseInt(v.length > 0 ? v : '0'); }, InputType.Number)
    }
  }

  @Builder
  SsFields() {
    Column({ space: 10 }) {
      this.Field($r('app.string.encryption_method'), 'aes-128-gcm / chacha20-ietf-poly1305 / 2022-*', this.p.method,
        (v: string) => { this.p.method = v; })
      this.Field($r('app.string.password'), 'password', this.p.password, (v: string) => { this.p.password = v; })
    }
  }

  @Builder
  VmessFields() {
    Column({ space: 10 }) {
      this.Field('UUID', 'uuid', this.p.uuid, (v: string) => { this.p.uuid = v; })
      this.Field('alterId', '0', `${this.p.alterId}`, (v: string) => { this.p.alterId = parseInt(v.length > 0 ? v : '0'); },
        InputType.Number)
      this.Field($r('app.string.encryption_security'), 'auto', this.p.security, (v: string) => { this.p.security = v; })
    }
  }

  @Builder
  VlessFields() {
    Column({ space: 10 }) {
      this.Field('UUID', 'uuid', this.p.uuid, (v: string) => { this.p.uuid = v; })
      this.Field('Flow', $r('app.string.empty_or_xtls_vision'), this.p.flow, (v: string) => { this.p.flow = v; })
    }
  }

  @Builder
  PasswordFields(label: ResourceStr) {
    this.Field(label, 'password', this.p.password, (v: string) => { this.p.password = v; })
  }

  @Builder
  HysteriaFields() {
    Column({ space: 10 }) {
      this.Field($r('app.string.auth_string'), 'auth', this.p.password, (v: string) => { this.p.password = v; })
      this.Field($r('app.string.upload_mbps'), '100', `${this.p.upMbps}`, (v: string) => { this.p.upMbps = parseInt(v.length > 0 ? v : '0'); },
        InputType.Number)
      this.Field($r('app.string.download_mbps'), '100', `${this.p.downMbps}`, (v: string) => { this.p.downMbps = parseInt(v.length > 0 ? v : '0'); },
        InputType.Number)
      this.Field('obfs (Salamander)', $r('app.string.empty_or_password'), this.p.obfs, (v: string) => { this.p.obfs = v; })
    }
  }

  @Builder
  Hysteria2Fields() {
    Column({ space: 10 }) {
      this.PasswordFields($r('app.string.password_hysteria2'))
      this.Field($r('app.string.upload_mbps_optional'), '100', ``, (v: string) => { this.p.upMbps = parseInt(v.length > 0 ? v : '0'); }, InputType.Number)
      this.Field($r('app.string.download_mbps_optional'), '100', ``, (v: string) => { this.p.downMbps = parseInt(v.length > 0 ? v : '0'); }, InputType.Number)
      this.Field($r('app.string.obfs_password_optional'), $r('app.string.salamander_password'), this.p.obfs, (v: string) => { this.p.obfs = v; })
    }
  }

  @Builder
  TuicFields() {
    Column({ space: 10 }) {
      this.Field('UUID', 'uuid', this.p.uuid, (v: string) => { this.p.uuid = v; })
      this.Field($r('app.string.password'), $r('app.string.password_optional_placeholder'), this.p.password, (v: string) => { this.p.password = v; })
      this.Field($r('app.string.congestion_control'), 'bbr / cubic / new_reno', this.p.congestionControl, (v: string) => { this.p.congestionControl = v; })
      this.Field($r('app.string.udp_relay_mode'), 'native / quic', this.p.udpRelayMode, (v: string) => { this.p.udpRelayMode = v; })
    }
  }

  @Builder
  WireguardFields() {
    Column({ space: 10 }) {
      this.Field($r('app.string.local_address_cidr'), '172.16.0.2/32', this.p.localAddress, (v: string) => { this.p.localAddress = v; })
      this.Field($r('app.string.private_key'), '', this.p.privateKey, (v: string) => { this.p.privateKey = v; })
      this.Field($r('app.string.peer_public_key'), '', this.p.peerPublicKey, (v: string) => { this.p.peerPublicKey = v; })
      this.Field($r('app.string.pre_shared_key_optional'), '', this.p.preSharedKey, (v: string) => { this.p.preSharedKey = v; })
    }
  }

  @Builder
  UserPassFields() {
    Column({ space: 10 }) {
      this.Field($r('app.string.username_optional'), 'username', this.p.username, (v: string) => { this.p.username = v; })
      this.Field($r('app.string.password_optional'), 'password', this.p.password, (v: string) => { this.p.password = v; })
    }
  }

  @Builder
  TransportFields() {
    Column() {
      Text($r('app.string.transport')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Select(TRANSPORTS.map((t: string) => ({ value: t === '' ? $r('app.string.tcp_none') : t } as SelectOption)))
        .selected(TRANSPORTS.indexOf(this.p.transport) < 0 ? 0 : TRANSPORTS.indexOf(this.p.transport))
        .value(this.p.transport === '' ? $r('app.string.tcp_none') : this.p.transport)
        .onSelect((index: number) => { this.p.transport = TRANSPORTS[index]; })
      if (this.p.transport === 'ws' || this.p.transport === 'http' || this.p.transport === 'httpupgrade') {
        this.Field('Path', '/', this.p.path, (v: string) => { this.p.path = v; })
        this.Field('Host', $r('app.string.domain_placeholder'), this.p.host, (v: string) => { this.p.host = v; })
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
        Text($r('app.string.enable_tls')).fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.p.tls })
          .onChange((v: boolean) => { this.p.tls = v; })
      }.width('100%')

      this.Field('SNI', $r('app.string.sni_placeholder'), this.p.sni, (v: string) => { this.p.sni = v; })
      this.Field($r('app.string.alpn_comma_separated'), $r('app.string.alpn_placeholder'), this.p.alpn, (v: string) => { this.p.alpn = v; })
      this.Field($r('app.string.utls_fingerprint'), 'chrome / firefox / safari / ios…', this.p.fingerprint, (v: string) => { this.p.fingerprint = v; })
      this.Field($r('app.string.reality_public_key_optional'), '', this.p.realityPublicKey, (v: string) => { this.p.realityPublicKey = v; })
      this.Field($r('app.string.reality_short_id_optional'), '', this.p.realityShortId, (v: string) => { this.p.realityShortId = v; })

      Row() {
        Text($r('app.string.allow_insecure_tls')).fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.p.allowInsecure })
          .onChange((v: boolean) => { this.p.allowInsecure = v; })
      }.width('100%')

      Row() {
        Text($r('app.string.multiplex')).fontSize(14).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.p.mux })
          .onChange((v: boolean) => { this.p.mux = v; })
      }.width('100%')
    }
  }

  @Builder
  AdvancedFields() {
    Column({ space: 10 }) {
      this.Field($r('app.string.extra_json_advanced'), '{"dialer":{}}', this.p.extra,
        (v: string) => { this.p.extra = v; })
      Text($r('app.string.profile_edit_footer_hint'))
        .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
    }
  }
}
