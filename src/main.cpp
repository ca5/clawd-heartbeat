#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <FastLED.h>

// ---- ユーザー設定 ----
#include "secrets.h"   // WIFI_SSID / WIFI_PASS(gitignore 済み)。SSID を空にすると WiFi を使わず USB / BLE のみで動く
const char* HOSTNAME  = "atom";
const bool  BLE_ENABLED = true;     // BLE(Bluetooth Low Energy)で受け付ける。Mac 側は常駐デーモン(ble-bridge.py)が接続を保持する
const char* BLE_NAME    = "clawd-heartbeat";
const uint8_t BRIGHTNESS = 255;     // ケース(拡散シェード)前提で最大。裸運用なら 30〜50 に戻す
// ----------------------

// BLE GATT。Nordic UART Service(NUS)互換の UUID を使う(汎用ツールでも扱える)。
//   RX(write / write-no-response): Mac → Atom のコマンド("led s=tool sid=x ts=123" 等の 1 行)
//   TX(read / notify):            Atom → Mac の応答。status は read で statusBody() を返す
#define BLE_SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_RX_UUID      "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define BLE_TX_UUID      "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

#define LED_PIN 27
#define BTN_PIN 39                        // 本体前面ボタン(押下で LOW)
#define RAINBOW_MS 10000UL                // ボタン押下でレインボー表示する時間
#define STALE_MS (10UL * 60UL * 1000UL)   // 10分更新がないセッションは失効
#define DEFAULT_STALE_MS (2UL * 60UL * 1000UL) // 手動送信(sid=default)は 2分で失効(テストの残留対策)
#define OFF_MS   (30UL * 60UL * 1000UL)   // 30分リクエストがなければ消灯
#define DONE_MS  6000UL                   // done の表示時間
#define WAIT_BLINK_MS 30000UL             // wait の点滅時間(以降は常時点灯で 10 分待って idle へ)
#define WIFI_BOOT_MS 20000UL              // 起動直後に WiFi 接続待ち(紫)を表示する最大時間
#define WIFI_RETRY_MS (5UL * 60UL * 1000UL) // 無線併用時、WiFi 未接続なら再接続を試みる間隔
#define SERIAL_LINE_MAX 200               // シリアル/BLE コマンド 1 行の最大長(超えた行は捨てる)
#define BLE_RX_RING 512                   // BLE 受信リングバッファ(BLE タスク → loop の受け渡し)
#define BLE_MAX_CONN 3                    // 同時に接続できる central の数(ESP32 の上限 = 3)
#define MAX_SESSIONS 8

CRGB leds[1];
WebServer server(80);

// 入力経路は 3 つ: WiFi 経由の HTTP(/led 等)、USB シリアル、BLE。
// USB と BLE は同じ行コマンド(led ... 等)を渡すだけの違い。
// 状態更新のロジックは共通(applyLed / applyRgb / statusBody)で、経路はその薄いラッパー
bool wifiConfigured = false;      // secrets.h の SSID が空でない
bool httpStarted = false;         // WiFi 接続後に mDNS / WebServer を起動済み
bool bleReady = false;            // BLE 初期化済み
volatile int bleConns = 0;        // 現在接続中の central 数(複数マシン対応)
bool anyCommand = false;          // 起動後に 1 回でもコマンド(HTTP / シリアル / BLE)を受けた
unsigned long bootMs = 0;
unsigned long wifiAttemptMs = 0;  // 最後に WiFi.begin() した時刻(間欠再接続用)

BLECharacteristic* txChar = nullptr;   // Atom → Mac(read / notify)

// BLE 受信リング(単一生産者=BLE タスク / 単一消費者=loop の SPSC。ロック不要)
volatile uint8_t bleRing[BLE_RX_RING];
volatile size_t bleHead = 0, bleTail = 0;

enum State { IDLE, TOOL, WAIT, DONE, ERR };
const char* STATE_NAMES[] = {"idle", "tool", "wait", "done", "err"};

// 複数の Claude Code セッションが同時に叩いても上書きし合わないよう、
// セッション別に状態を持ち、表示は優先度(wait > err > done > tool > idle)で集約する
struct Session {
  char id[48];
  State st;
  unsigned long since;   // この状態になった時刻(done の失効判定用)
  unsigned long seen;    // 最終更新時刻(セッション失効判定用)
  uint64_t lastTs;       // 最後に適用した送信タイムスタンプ(順序逆転の排除用)
  bool used;
};
Session sessions[MAX_SESSIONS];

State shown = IDLE;               // 現在表示中の集約状態
unsigned long shownSince = 0;     // 点滅の位相基準
unsigned long waitSince = 0;      // 最新の wait 開始時刻(点滅→常灯の切替基準)
unsigned long lastRequest = 0;

bool rawActive = false;           // 発光テスト(/rgb)の直接制御中
CRGB rawColor = CRGB::Black;
unsigned long rawSince = 0;

bool rainbowActive = false;       // ボタン押下によるレインボー表示中
unsigned long rainbowSince = 0;   // レインボー開始時刻

Session* findSlot(const String& sid) {
  for (auto& s : sessions) if (s.used && sid == s.id) return &s;
  for (auto& s : sessions) if (!s.used) return &s;
  Session* oldest = &sessions[0];
  for (auto& s : sessions) if (s.seen < oldest->seen) oldest = &s;
  return oldest;
}

unsigned long staleFor(const Session& s) {
  return (strcmp(s.id, "default") == 0) ? DEFAULT_STALE_MS : STALE_MS;
}

// 状態更新の本体。戻り値は応答文字列("ok" / "stale" / "unknown state")
const char* applyLed(const String& s, String sid, uint64_t ts) {
  State st;
  if      (s == "tool") st = TOOL;
  else if (s == "wait") st = WAIT;
  else if (s == "done") st = DONE;
  else if (s == "err")  st = ERR;
  else if (s == "idle") st = IDLE;
  else return "unknown state";

  if (sid.length() == 0) sid = "default";

  unsigned long now = millis();
  anyCommand = true;
  Session* slot = findSlot(sid);
  if (!slot->used || sid != slot->id) {
    strncpy(slot->id, sid.c_str(), sizeof(slot->id) - 1);
    slot->id[sizeof(slot->id) - 1] = 0;
    slot->used = true;
    slot->st = IDLE;
    slot->since = now;
    slot->lastTs = 0;
  }

  // async hook + リトライで届く順序が逆転することがあるため、
  // 送信タイムスタンプ(ts)が前回適用分より古い更新は捨てる(ts なしは常に適用)
  if (ts > 0 && ts < slot->lastTs) {
    slot->seen = now;   // セッションは生きているので失効タイマーだけ更新
    return "stale";
  }
  if (ts > 0) slot->lastTs = ts;

  if (slot->st != st) slot->since = now;
  slot->st = st;
  slot->seen = now;

  rawActive = false;
  lastRequest = now;
  return "ok";
}

// 発光テスト用: 任意色を直接点灯(次の led コマンドで通常動作に戻る)
void applyRgb(int r, int g, int b) {
  rawColor = CRGB(r, g, b);
  rawActive = true;
  anyCommand = true;
  rawSince = millis();
  lastRequest = rawSince;
}

State aggregate(unsigned long now) {
  bool anyWait = false, anyErr = false, anyDone = false, anyTool = false;
  for (auto& s : sessions) {
    if (!s.used || now - s.seen > staleFor(s)) continue;
    State st = s.st;
    if (st == DONE && now - s.since > DONE_MS) st = IDLE;
    if (st == WAIT && s.since > waitSince) waitSince = s.since;
    if      (st == WAIT) anyWait = true;
    else if (st == ERR)  anyErr  = true;
    else if (st == DONE) anyDone = true;
    else if (st == TOOL) anyTool = true;
  }
  if (anyWait) return WAIT;
  if (anyErr)  return ERR;
  if (anyDone) return DONE;
  if (anyTool) return TOOL;
  return IDLE;
}

int activeSessions(unsigned long now) {
  int n = 0;
  for (auto& s : sessions) if (s.used && now - s.seen <= staleFor(s)) n++;
  return n;
}

// 集約状態とセッション別内訳(HTTP / シリアル / BLE の status で共通)。
// ヘッダ行は key=value、セッション行は 2 スペースのインデントで始まる
String statusBody() {
  unsigned long now = millis();
  String wifi = !wifiConfigured ? "off"
              : (WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "connecting");
  String ble = !bleReady ? "off" : (bleConns > 0 ? (String("connected n=") + bleConns) : "advertising");
  String body = String("state=") + (rawActive ? "raw" : STATE_NAMES[(int)aggregate(now)]) +
    "\nsessions=" + String(activeSessions(now)) +
    "\nuptime=" + String(now / 1000) + "s" +
    "\nrssi=" + String(httpStarted ? WiFi.RSSI() : 0) +
    "\nwifi=" + wifi +
    "\nble=" + ble + "\n";
  for (auto& s : sessions) {
    if (!s.used || now - s.seen > staleFor(s)) continue;
    body += String("  ") + s.id + " " + STATE_NAMES[(int)s.st] +
            " age=" + String((now - s.seen) / 1000) + "s\n";
  }
  return body;
}

// ---- HTTP 経路 ----

void handleLed() {
  const char* r = applyLed(server.arg("s"), server.arg("sid"),
                           strtoull(server.arg("ts").c_str(), nullptr, 10));
  server.send(strcmp(r, "unknown state") == 0 ? 400 : 200, "text/plain", String(r) + "\n");
}

void handleRgb() {
  applyRgb(server.arg("r").toInt(), server.arg("g").toInt(), server.arg("b").toInt());
  server.send(200, "text/plain", "ok\n");
}

void startHttp() {
  MDNS.begin(HOSTNAME);
  MDNS.addService("http", "tcp", 80);
  server.on("/led", handleLed);
  server.on("/rgb", handleRgb);
  server.on("/", []() { server.send(200, "text/plain", statusBody()); });
  server.begin();
  httpStarted = true;
  Serial.print("ready: http://");
  Serial.println(WiFi.localIP());
  Serial.print("mac: ");
  Serial.println(WiFi.macAddress());
}

// ---- 行コマンド(USB シリアル / BLE 共通)----
// 1 行 1 コマンド(改行終端)。HTTP と同じ引数を "key=value" で渡す:
//   led s=<state> [sid=<id>] [ts=<ms>]   → ok / stale / unknown state
//   rgb r=<0-255> g=<0-255> b=<0-255>    → ok
//   status                               → statusBody() の後に空行

// コマンド行から " key=" に続く値を取り出す(なければ空文字)
String argOf(const String& line, const char* key) {
  String k = String(" ") + key + "=";
  int i = line.indexOf(k);
  if (i < 0) return "";
  i += k.length();
  int j = line.indexOf(' ', i);
  if (j < 0) j = line.length();
  return line.substring(i, j);
}

// 1 行を処理して応答文字列を返す(status は末尾に空行を付ける)
String handleLine(String line) {
  line.trim();
  if (line.length() == 0) return "";
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  if (cmd == "led") {
    return String(applyLed(argOf(line, "s"), argOf(line, "sid"),
                           strtoull(argOf(line, "ts").c_str(), nullptr, 10))) + "\n";
  } else if (cmd == "rgb") {
    applyRgb(argOf(line, "r").toInt(), argOf(line, "g").toInt(), argOf(line, "b").toInt());
    return "ok\n";
  } else if (cmd == "status") {
    return statusBody() + "\n";     // 空行で終端(読み手はここで打ち切る)
  }
  return "unknown command\n";
}

// ---- USB シリアル経路 ----
struct LineReader {
  char buf[SERIAL_LINE_MAX];
  size_t len = 0;
  bool overflow = false;
};
LineReader usbReader;

void pollSerial() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (usbReader.len > 0 && !usbReader.overflow) {
        usbReader.buf[usbReader.len] = 0;
        Serial.print(handleLine(String(usbReader.buf)));
      }
      usbReader.len = 0;
      usbReader.overflow = false;
    } else if (usbReader.len < sizeof(usbReader.buf) - 1) {
      usbReader.buf[usbReader.len++] = c;
    } else {
      usbReader.overflow = true;      // 長すぎる行(ノイズ・混線)は行末まで捨てる
    }
  }
}

// ---- BLE 経路 ----
// 接続を張るのは Mac 側の常駐デーモン(ble-bridge.py)。デーモンは接続を保持したまま
// RX へコマンドを write する。BLE の接続は張りっぱなしで維持されるため、SPP のような
// 開くたびの再接続待ちが無い。write は BLE タスクで走るので、ここではリングに積むだけにして
// 実処理(applyLed 等)は loop() で行う(sessions[] や FastLED を 1 スレッドに寄せる)。
class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue().c_str();
    for (size_t i = 0; i < v.length(); i++) {
      size_t next = (bleHead + 1) % BLE_RX_RING;
      if (next == bleTail) break;     // 満杯(消費が追いつかない)なら以降を捨てる
      bleRing[bleHead] = (uint8_t)v[i];
      bleHead = next;
    }
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    if (bleConns < BLE_MAX_CONN) bleConns++;
    // 1 台目の接続後も広告を続け、2 台目以降(別マシン)も受け付ける。上限まで
    if (bleConns < BLE_MAX_CONN) s->startAdvertising();
  }
  void onDisconnect(BLEServer* s) override {
    if (bleConns > 0) bleConns--;
    s->startAdvertising();           // 空きができたので再び広告
  }
};

void startBle() {
  BLEDevice::init(BLE_NAME);
  BLEServer* srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerCallbacks());
  BLEService* svc = srv->createService(BLE_SERVICE_UUID);

  BLECharacteristic* rx = svc->createCharacteristic(
    BLE_RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCallbacks());

  txChar = svc->createCharacteristic(
    BLE_TX_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  txChar->setValue(statusBody().c_str());

  svc->start();
  // BLE の広告は 31 バイト上限。128bit UUID(18B)+ 名前(17B)を両方メイン広告に載せると
  // 溢れて広告設定ごと失敗し、何も見えなくなる(実測)。UUID をメイン広告、名前をスキャン応答に分ける
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  BLEAdvertisementData advData;
  advData.setFlags(0x06);                       // LE General Discoverable + BR/EDR 非対応
  advData.setCompleteServices(BLEUUID(BLE_SERVICE_UUID));
  adv->setAdvertisementData(advData);
  BLEAdvertisementData scanResp;
  scanResp.setName(BLE_NAME);
  adv->setScanResponseData(scanResp);
  BLEDevice::startAdvertising();
  bleReady = true;
  Serial.print("ble: "); Serial.println(BLE_NAME);
}

// リングに溜まった BLE 受信を行に組み立てて処理する(loop から呼ぶ)
void pollBle() {
  static LineReader r;
  while (bleTail != bleHead) {
    char c = (char)bleRing[bleTail];
    bleTail = (bleTail + 1) % BLE_RX_RING;
    if (c == '\n' || c == '\r') {
      if (r.len > 0 && !r.overflow) {
        r.buf[r.len] = 0;
        String resp = handleLine(String(r.buf));
        if (txChar && resp.length()) {        // 応答は TX に載せる(read で取れる。購読時は notify)
          txChar->setValue(resp.c_str());
          if (bleConns > 0) txChar->notify();
        }
      }
      r.len = 0;
      r.overflow = false;
    } else if (r.len < sizeof(r.buf) - 1) {
      r.buf[r.len++] = c;
    } else {
      r.overflow = true;
    }
  }
}

// ---- 表示 ----

void render() {
  unsigned long now = millis();

  // ボタン押下によるレインボー(10 秒): 何よりも優先して表示
  // 減算で判定(millis() オーバーフロー対策。絶対値比較だと 49.7 日周回後に誤発動する)
  if (rainbowActive) {
    if (now - rainbowSince < RAINBOW_MS) {
      leds[0] = CHSV((uint8_t)(now / 8), 255, 255);   // 約 2 秒で色相一周
      FastLED.show();
      return;
    }
    rainbowActive = false;
  }

  // 起動直後の WiFi 接続待ち(紫)。接続するか、最初のコマンドを受けるか、20 秒経過で終わる。
  // WiFi なし(SSID 空)ならこの表示は出ず、起動直後から idle の青
  if (wifiConfigured && !httpStarted && !anyCommand && now - bootMs < WIFI_BOOT_MS) {
    leds[0] = CRGB::Purple;
    FastLED.show();
    return;
  }

  // 30分リクエストがなければ消灯(次のリクエストで復帰)
  if (now - lastRequest > OFF_MS) {
    leds[0] = CRGB::Black;
    FastLED.show();
    return;
  }

  if (rawActive) {
    if (now - rawSince > STALE_MS) rawActive = false;
    leds[0] = rawColor;
    FastLED.show();
    return;
  }

  State agg = aggregate(now);
  if (agg != shown) {
    shown = agg;
    shownSince = now;
  }
  unsigned long t = now - shownSince;
  CRGB c = CRGB::Black;

  switch (shown) {
    case IDLE:
      // BLE 有効かつ未接続(Mac の Bluetooth オフ / デーモン停止 / まだ繋がっていない)は、
      // 青のゆっくり点滅で「リンク待ち」を示す。接続中は従来どおり青の常灯。
      // 1 秒周期の点滅は wait(400ms)/done(150ms)/err(120ms)と速度で区別できる。
      // 新しい状態が届いていれば必ず接続中なので、この区別が要るのは idle のときだけ
      if (BLE_ENABLED && bleConns == 0)
        c = ((now / 1000) % 2) ? CRGB(CHSV(160, 255, 110)) : CRGB(CRGB::Black);   // 青のゆっくり点滅
      else
        c = CHSV(160, 255, 128);                       // 青の常灯(フルの 1/2。ケース越し視認用)
      break;
    case TOOL:
      c = CRGB::White;                                 // 白の呼吸(オレンジケース越しでも赤と混同しない)
      c.nscale8(beatsin8(40, 10, 255));
      break;
    case WAIT:
      // 最初の 30 秒は点滅で気づかせ、以降は常灯(離席から戻ったとき用)
      if (now - waitSince < WAIT_BLINK_MS)
        c = ((t / 400) % 2) ? CRGB(170, 0, 0) : CRGB::Black;   // err(120ms)より遅い点滅で区別
      else
        c = CRGB(170, 0, 0);
      break;
    case DONE:
      c = ((t / 150) % 2) ? CRGB::Green : CRGB::Black;
      break;
    case ERR:
      c = ((t / 120) % 2) ? CRGB::Red : CRGB::Black;
      break;
  }
  leds[0] = c;
  FastLED.show();
}

void setup() {
  Serial.begin(115200);
  pinMode(BTN_PIN, INPUT);   // GPIO39 は入力専用・基板側プルアップ、押下で LOW
  FastLED.addLeds<WS2812B, LED_PIN, GRB>(leds, 1);
  FastLED.setBrightness(BRIGHTNESS);

  bootMs = millis();
  lastRequest = bootMs;
  shownSince = bootMs;

  // WiFi はブロックせずに裏で接続する(USB / BLE は WiFi の有無に関係なく即使える)。
  // 20 秒で繋がらなくても再起動しない(再起動でセッション状態が消えるため)
  wifiConfigured = strlen(WIFI_SSID) > 0;
  if (wifiConfigured) {
    WiFi.mode(WIFI_STA);
    // モデムスリープ無効化は HTTP の応答遅延を抑えるためだが、BLE と共存させる場合は
    // ESP-IDF がスリープ有効を要求する(無効のままだと無線コントローラ有効化で abort する)
    WiFi.setSleep(BLE_ENABLED);
    // BLE 併用時は自動再接続を切る: AP が見えないと約 1.7 秒ごとに全チャンネルスキャンを
    // 繰り返し、無線を共有する BLE の広告が痩せる。代わりに loop() で間欠試行する
    WiFi.setAutoReconnect(!BLE_ENABLED);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    wifiAttemptMs = millis();
    Serial.println("boot: serial ready, connecting wifi");
  } else {
    WiFi.mode(WIFI_OFF);
    Serial.println("boot: serial ready (wifi off)");
  }

  // BLE ペリフェラル。BLE スタックが大きいので platformio.ini でアプリ領域 3MB(huge_app.csv)。
  // WiFi と同時に使う場合は上の WiFi.setSleep(true) が前提
  if (BLE_ENABLED) startBle();
}

void loop() {
  pollSerial();
  if (bleReady) pollBle();

  if (wifiConfigured) {
    if (!httpStarted && WiFi.status() == WL_CONNECTED) startHttp();
    if (httpStarted) server.handleClient();
  }

  // 前面ボタン: 押下(立ち下がり)でレインボー 10 秒。消灯中でも起きる
  static bool btnPrev = true;
  static unsigned long btnLast = 0;
  bool btn = digitalRead(BTN_PIN);
  if (btnPrev && !btn && millis() - btnLast > 250) {   // 250ms デバウンス
    btnLast = millis();
    rainbowSince = millis();
    rainbowActive = true;
    lastRequest = millis();   // 自動消灯タイマーもリセット(押せば必ず光る)
  }
  btnPrev = btn;

  render();

  // status を購読していない読み手のために TX を定期更新(read で最新が取れる)
  static unsigned long lastTx = 0;
  if (bleReady && txChar && millis() - lastTx > 1000) {
    lastTx = millis();
    txChar->setValue(statusBody().c_str());
  }

  // WiFi 断の復旧: 再起動はせず再接続を促すだけ(再起動するとセッション状態が消える)。
  // BLE 併用時は WIFI_RETRY_MS ごとの間欠試行(理由は setup() のコメント参照)
  static unsigned long lastCheck = 0;
  if (wifiConfigured && millis() - lastCheck > 30000) {
    lastCheck = millis();
    if (WiFi.status() != WL_CONNECTED) {
      if (!BLE_ENABLED) {
        WiFi.reconnect();
      } else if (millis() - wifiAttemptMs > WIFI_RETRY_MS) {
        wifiAttemptMs = millis();
        WiFi.disconnect();
        WiFi.begin(WIFI_SSID, WIFI_PASS);
        Serial.println("wifi: retry");
      }
    }
  }
}
