# Sonora, macOS Ses Ekolayzırı ve Mixer'ı, Tasarım Dokümanı

- **Tarih:** 2026-09-07
- **Durum:** Onaylandı
- **Çalışma adı:** Sonora (tek yeniden adlandırma ile değiştirilebilir)
- **Depo:** `~/Projects/Kisisel/sonora`
- **Lisans:** MIT
- **Hedef platform:** macOS 14.4 ve üstü, geliştirme ve test makinesi macOS 26.5, Xcode 26.3, Swift 6.2

---

## 1. Problem

macOS'ta sistem sesi üzerinde tek bir kontrol vardır: genel ses seviyesi. İşletim sisteminde ekolayzır yoktur, uygulama bazlı ses kontrolü yoktur, çıkış cihazına göre ses profili yoktur. Kullanıcı MacBook hoparlöründe bas eksikliğini düzeltemez, Spotify'ı kısıp Zoom'u açık bırakamaz, kulaklığının frekans eğrisini düzeltemez.

Ticari çözümler vardır (SoundSource, Boom) ama ücretlidir ve kapalı kaynaktır. Açık kaynak seçenek olan eqMac bir HAL sürücüsü kurar, bu da yönetici şifresi ve kırılgan kurulum demektir.

Sonora bu boşluğu doldurur: sürücü kurulumu olmadan, sürükle bırak kurulumla çalışan, tamamen açık kaynak bir sistem ekolayzırı ve uygulama mixer'ı.

## 2. Hedefler ve hedef olmayanlar

### Hedefler

- Sistem geneli 10 bant grafik ekolayzır, gelişmiş modda tam parametrik kontrol
- Sistem sınırının üstüne çıkabilen preamp, arkasında yumuşak limiter
- Menü çubuğu ikonu ve ses tuşları ile açılan hızlı erişim paneli
- Çıkış cihazına göre otomatik profil değişimi
- AutoEq veritabanından kulaklık düzeltme eğrileri
- Uygulama bazlı ses seviyesi ve ekolayzır
- Canlı spektrum analizörü
- Yönetici şifresi istemeyen kurulum

### Hedef olmayanlar

- Mac App Store dağıtımı. App Sandbox kapalı olmak zorunda, bu MAS'ı dışlar.
- iOS veya iPadOS desteği. Platform tap API'sine izin vermiyor.
- Ses kaydı veya dosyaya yazma. Sonora sesi işler, saklamaz.
- Ticari lisans katmanı, ödeme, kullanıcı hesabı. Ürün tamamen ücretsiz.

## 3. Faz bölümü

Ürünün tamamı tek bir spec'e sığmaz. Beş faza bölünür, her fazın sonunda çalışan ve yayınlanabilir bir sürüm vardır. Bu doküman Faz 0 ve Faz 1'i tanımlar, kalan fazlar yol haritası olarak kayıtlıdır ve kendi spec ve planlarını alacaktır.

| Faz | İçerik | Çıktı |
|---|---|---|
| 0. Spike | Global tap, aggregate device, IOProc passthrough, imzalı build, TCC izni, gecikme ölçümü | Ses geçiyor, gecikme rakamı elde |
| 1. Çekirdek | Ses motoru, 10 bant EQ, preamp ve limiter, menü çubuğu paneli, ses tuşu yakalama, preset'ler | v0.1, yayına çıkar |
| 2. Görsel ve derinlik | Spektrum analizörü, parametrik gelişmiş mod, denge, mono, çıkış gecikmesi | v0.2 |
| 3. Profiller | Cihaz bazlı otomatik profil, AutoEq kulaklık kütüphanesi | v0.3 |
| 4. Mixer | Uygulama bazlı ses ve EQ, helper process gruplama | v0.4 |
| 5. Yedek motor | AudioDriverKit sistem uzantısı, tap'in yetmediği durumlar | v1.0 |

Faz 5'in yeri koşulludur: Faz 0'daki gecikme ölçümü kabul edilemez çıkarsa Faz 5 öne alınır ve birincil motor olur.

## 4. Ses motoru mimarisi

### 4.1 Sinyal yolu

```
Uygulama sesi
  -> CATapDescription(stereoGlobalTapButExcludeProcesses: [kendi PID])
     muteBehavior = .mutedWhenTapped
     isPrivate = true
  -> AudioHardwareCreateProcessTap
  -> Private aggregate device
       ana alt cihaz: gerçek varsayılan çıkış cihazı
       alt-tap: yukarıdaki tap'in UUID'si
       kAudioAggregateDeviceTapAutoStartKey: true
       kAudioAggregateDeviceIsPrivateKey: true
  -> AudioDeviceCreateIOProcIDWithBlock (DSP burada çalışır)
  -> gerçek çıkış cihazı
```

### 4.2 Doğrulanmış kısıtlar

Bu üç madde araştırma ile doğrulanmıştır ve mimariyi belirler:

1. **AVAudioEngine kullanılamaz.** CATap destekli aggregate cihaza yönlendirilemez. `kAudioOutputUnitProperty_CurrentDevice` ataması `noErr` döner ama motor sessizce varsayılan girişi okumaya devam eder. Bu yüzden `AVAudioUnitEQ` gibi hazır birimler kullanılamaz, DSP ham IOProc bloğu içinde elle yazılır.
2. **`CATapDescription.isExclusive` bir yön bayrağıdır**, kilit anahtarı değildir. `stereoGlobalTapButExcludeProcesses:` başlatıcısı bu bayrağı zaten ayarlar. Sonradan değiştirmek semantiği "listelenenler hariç her şey"den "sadece listelenenler"e çevirir ve tap sessizlik yakalar.
3. **Tap, aggregate cihazın ana alt cihazı olamaz.** Gerçek bir çıkış cihazı ana alt cihaz olmalıdır, tap alt-tap olarak eklenir. Boş alt cihaz listesiyle kurulan aggregate hata vermeden sıfır örnek üretir.

### 4.3 Gerçek zamanlı güvenlik

IOProc bloğu gerçek zamanlı bir iş parçacığında çalışır. İçinde şunlar yasaktır: kilit alma, bellek ayırma, Swift runtime metadata çağrısı, Objective-C mesajı, dosya veya log erişimi.

Parametre aktarımı: arayüz iş parçacığı yeni bir `EngineParameters` değeri hazırlar ve atomik pointer takası ile yayınlar. IOProc her çağrıda geçerli snapshot'ı okur. Snapshot değeri POD (plain old data) bir struct'tır, referans saymaz.

Zipper gürültüsü ve tık sesi kontrolü: kazanç değişimleri ve filtre katsayısı geçişleri 30 ms zaman sabitli üstel rampa ile yumuşatılır.

```
rampCoefficient = 1 - exp(-1 / (sampleRate * 0.030))
```

### 4.4 Panik bypass

Motor hiçbir koşulda kullanıcıyı sessiz bırakmaz. Şu olaylarda tap ve aggregate yıkılır, ses normal sistem yoluna döner:

- TCC izni reddedildi veya iptal edildi
- Tap veya aggregate oluşturma başarısız
- Varsayılan çıkış cihazı kayboldu
- coreaudiod yeniden başladı
- Akış formatı beklenmedik şekilde değişti
- Kullanıcı menüden "Bypass" seçti

Uygulama çökerse tap nesnesi süreçle birlikte yok olur ve ses geri döner. Bu davranış Faz 0'da açıkça doğrulanacaktır (uygulamayı `kill -9` ile öldür, sesin geri geldiğini gör).

### 4.5 Cihaz değişimi

`kAudioHardwarePropertyDefaultOutputDevice` üzerine `AudioObjectAddPropertyListenerBlock` ile dinleyici kurulur. Değişim geldiğinde sıra şudur:

1. Mevcut durum (bant kazançları, preamp, bypass durumu) belleğe alınır
2. IOProc durdurulur, aggregate ve tap yok edilir
3. Yeni varsayılan çıkış cihazı okunur
4. Tap ve aggregate yeni cihaza göre kurulur
5. Kaydedilen durum geri yüklenir, IOProc başlatılır

Faz 3'te bu akışa cihaz profili eşlemesi eklenir: yeni cihazın UID'sine kayıtlı bir profil varsa kaydedilen durum yerine o profil yüklenir.

## 5. Modüller

Tek depo. Yerel Swift Package Manager paketleri ve bunları tüketen bir Xcode uygulama hedefi.

| Modül | Sorumluluk | Bağımlılık |
|---|---|---|
| `AudioDSP` | Biquad filtre (RBJ katsayıları), 10 bantlık kaskad, preamp, yumuşak limiter, denge ve mono, gecikme hattı, vDSP tabanlı FFT ölçer | Accelerate |
| `AudioEngine` | `TapSession`, `AggregateDeviceBuilder`, `DeviceWatcher`, `RenderLoop`, parametre köprüsü | CoreAudio, `AudioDSP` |
| `Profiles` | Preset veri modeli, yerleşik preset'ler, kullanıcı preset'leri, AutoEq `ParametricEQ.txt` ayrıştırıcı, cihaz eşleme | `AudioDSP` |
| `Persistence` | Application Support altında JSON ayar deposu, sürüm göçü | Yok |
| `SystemInput` | `CGEventTap` ile ses tuşu yakalama, global kısayol, HUD tetikleme | AppKit |
| `Permissions` | TCC ses kaydı izni akışı, Erişilebilirlik izni, ilk kurulum ekranı | AppKit |
| `App` | `NSStatusItem`, `NSPanel` içinde SwiftUI panel, EQ eğrisi görünümü, spektrum görünümü | Hepsi |

Sınır kuralı: `AudioDSP` Core Audio'yu tanımaz. Saf giriş çıkış tampon dönüşümü yapar. Bu sayede motorun test edilmesi en zor parçası, test edilmesi en kolay parça haline gelir.

`AudioEngine` arayüzü tanımaz. Dışarıya `start()`, `stop()`, `apply(parameters:)`, `state` ve olay yayını verir.

`App` katmanı Core Audio tipleri görmez, sadece `AudioEngine`'in kendi tiplerini görür.

## 6. DSP tasarımı

### 6.1 Bant yapısı

Varsayılan grafik mod, ISO standart 10 bant merkez frekansları:

`32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz`

Her bant bir peaking (bell) biquad'dır, Q sabit 1.41, kazanç aralığı -12 ile +12 dB. Kanal başına ayrı filtre durumu tutulur.

Gelişmiş parametrik mod (Faz 2) aynı biquad motorunu kullanır, tek fark bant sayısının, frekansın, Q'nun ve filtre tipinin (peak, low shelf, high shelf, high pass, low pass) serbest olmasıdır. Grafik mod, parametrik modun sabitlenmiş bir görünümüdür, ayrı bir kod yolu değildir.

### 6.2 Preamp ve limiter

Preamp -12 ile +12 dB. Kullanıcı sistem seviyesinin üstüne çıkabilir. Kırpılmayı önlemek için zincirin sonunda yumuşak limiter vardır: eşik üstünde `tanh` tabanlı yumuşak doyum, çıkış tavanı -0.3 dBFS. Limiter'ın devrede olduğu arayüzde küçük bir gösterge ile bildirilir.

EQ kazançları toplamı pozitifse otomatik preamp düşürme önerilir ama zorlanmaz. Kullanıcı kararı verir.

### 6.3 Ölçüm

Spektrum analizörü (Faz 2) IOProc'tan kopyalanan örnekleri lock-free bir halka tampona yazar. FFT ve pencereleme gerçek zamanlı iş parçacığında değil, arayüz tarafında 60 Hz'de çalışan ayrı bir tüketicide yapılır. Analizör kapalıyken halka tampona yazma da kapatılır, sıfır maliyet.

## 7. Arayüz ve tetikleme

### 7.1 Menü çubuğu ve panel

Kendi `NSStatusItem`'imiz sistem ses ikonunun yanına oturur. Kullanıcı isterse sistem ikonunu Control Center ayarlarından gizler, Sonora tek ses kontrolü haline gelir.

İkona tıklayınca açılan `NSPanel`, Control Center'ın cam malzemesi ve ölçüleriyle uyumlu tasarlanır. Yerleşim yukarıdan aşağı:

1. Ana ses kaydırıcısı ve çıkış cihazı seçici. Bu kaydırıcı sistem çıkış seviyesini (`kAudioDevicePropertyVolumeScalar`) kontrol eder, Sonora'nın kendi kazancını değil.
2. Preamp kaydırıcısı. Bu Sonora'nın kendi dijital kazancıdır ve sistem seviyesinden bağımsızdır. 0 dB üstünde uyarı bölgesine geçer.
3. 10 bant EQ kaydırıcıları ve üstünde birleşik frekans eğrisi
4. Preset şeridi ve açık kapalı anahtarı

### 7.2 Ses tuşları

F11 ve F12 (ve donanım ses tuşları) `CGEventTap` ile yakalanır. Sistem HUD'u bastırılır, yerine Sonora paneli açılır ve tuşa basıldıkça seviye değişir.

Bu özellik Erişilebilirlik iznine bağlıdır. İzin verilmezse uygulama tam işlevsel kalır, sadece tuş yakalama devre dışı olur ve kullanıcıya ayarlarda tek tıkla izin verme yolu gösterilir. İzin asla zorunlu tutulmaz.

Ayrıca kullanıcının tanımlayabileceği global kısayol paneli açar.

## 8. Kalıcılık

Ayarlar `~/Library/Application Support/Sonora/settings.json` altında saklanır. Şema sürümlüdür, açılışta göç uygulanır.

Saklananlar: aktif preset, bant kazançları, preamp, bypass durumu, kullanıcı preset'leri, cihaz profilleri (Faz 3), uygulama bazlı ayarlar (Faz 4), global kısayol, tuş yakalama tercihi.

Dosya bozuksa veya okunamıyorsa varsayılanlara dönülür, bozuk dosya `.corrupt` uzantısıyla yedeklenir ve kullanıcıya bildirilir.

## 9. Hata yönetimi

| Durum | Davranış |
|---|---|
| TCC ses kaydı izni yok | Kurulum ekranı, neden gerektiğinin açıklaması, Sistem Ayarları'na kısayol. İzin gelene kadar bypass modda çalışır. |
| Erişilebilirlik izni yok | Tuş yakalama kapalı, kalan her şey çalışır. Ayarlarda uyarı satırı. |
| Tap oluşturulamadı | Bypass, menü çubuğu ikonunda uyarı işareti, tek tıkla tekrar dene. |
| Aggregate oluşturulamadı | Tap temizlenir, bypass. |
| Çıkış cihazı kayboldu | Yeniden kurulum akışı (bölüm 4.5). Yeni cihaz yoksa bypass. |
| coreaudiod yeniden başladı | Dinleyici tetiklenir, tam yeniden kurulum. |
| Format değişti | IOProc durur, yeni formata göre filtre durumları sıfırlanır, devam. |
| Ayar dosyası bozuk | Varsayılana dön, bozuğu yedekle, bildir. |

Kural: her hata yolu ya sesi geri verir ya da kullanıcıya görünür bir uyarı üretir. Sessiz yutulan hata yoktur.

## 10. Test stratejisi

**Birim testleri (`AudioDSP`):** Biquad katsayılarının analitik frekans yanıtı ile karşılaştırılması, dürtü yanıtı testleri, limiter'ın tavanı aşmadığının doğrulanması, rampa katsayısının hedef değere yakınsaması, mono ve denge dönüşümlerinin kanal enerjisi kontrolü.

**Birim testleri (`Profiles`):** AutoEq `ParametricEQ.txt` ayrıştırıcısının gerçek örnek dosyalarla testi, hatalı biçim dayanıklılığı, preset serileştirme gidiş dönüşü.

**Birim testleri (`Persistence`):** Şema göçü, bozuk dosya kurtarma.

**Motor testleri:** Core Audio nesneleri sahte oluşturulamaz. Bu yüzden `AudioEngine` için elle çalıştırılan bir doğrulama kontrol listesi tutulur ve her sürüm öncesi geçilir:

1. Ses geçiyor, EQ değişimi duyuluyor
2. Kulaklık tak ve çıkar, ses kesintisiz devam ediyor
3. Bluetooth cihaza geç, ses devam ediyor
4. Uygulamayı `kill -9` ile öldür, ses normale dönüyor
5. TCC iznini `tccutil reset SystemAudioCaptureRequests <bundle-id>` ile sıfırla, akış baştan çalışıyor
6. Preamp maksimumda kırpılma yok
7. Video oynatırken dudak senkronu kabul edilebilir

**Performans hedefi:** IOProc içinde işlem süresi tampon süresinin %20'sini geçmemeli. Faz 0'da ölçülür ve regresyon testi olarak takip edilir.

## 11. Dağıtım

- **İmzalama:** Zorunlu. TCC izin kaydı imza kimliğine bağlıdır, imzasız build'de izin diyaloğu hiç görünmez. Geliştirme sırasında Xcode üzerinden gerçek bir takım kimliği ile çalıştırılır.
- **Deployment target:** macOS 14.4. Alt sürümler farklı TCC kategorisine düşer ve diyalog metni değişir.
- **Entitlements:** `com.apple.security.app-sandbox = false` (CATap sandbox altında kırılgan), Hardened Runtime açık.
- **Info.plist:** `NSAudioCaptureUsageDescription` elle eklenir, Xcode listesinde görünmez.
- **Dağıtım kanalları:** Notarize edilmiş DMG, GitHub Releases, Homebrew cask, Sparkle ile otomatik güncelleme.
- **CI:** GitHub Actions macOS runner üzerinde build, test, imza, notarize, release. Bu native bir macOS uygulamasıdır, Docker uygulanabilir değildir.

## 12. Riskler

| Risk | Etki | Azaltma |
|---|---|---|
| Tap yolunun gecikmesi video senkronunu bozar | Ürün kullanılamaz | Faz 0 spike ilk günde ölçer. Kabul edilemezse Faz 5 (DriverKit) öne alınır ve birincil motor olur. |
| Apple tap API davranışını değiştirir | Motor bozulur | Panik bypass her durumda sesi geri verir. Sürüm bazlı davranış testleri kontrol listesinde. |
| TCC izin akışı kullanıcıyı kaybettirir | Kurulum tamamlanmaz | Net kurulum ekranı, izin verilmeden de bypass modda açılan çalışır uygulama. |
| Uygulama bazlı tap'lerde helper process karmaşası (tarayıcı, Electron) | Mixer'da anlamsız çift satırlar | Faz 4'te helper süreçleri ana uygulama altında gruplama kuralı. |
| Sandbox kapalı olduğu için MAS dışı kalınıyor | Erişim daralır | Kabul edilen kısıt. Homebrew cask ve GitHub dağıtımı hedef kitleye yeter. |

## 13. Faz 1 kabul kriterleri

Aşağıdakilerin hepsi sağlandığında v0.1 yayına hazırdır:

1. Uygulama açıldığında izin akışını tamamlar ve sistem sesini tap üzerinden geçirir
2. 10 bant EQ kaydırıcıları sesi gerçek zamanlı ve tık sesi olmadan değiştirir
3. Preamp sistem seviyesinin üstüne çıkar, limiter kırpılmayı engeller
4. Menü çubuğu ikonu ve ses tuşları paneli açar
5. Yerleşik preset'ler yüklenir, kullanıcı kendi preset'ini kaydeder
6. Ayarlar yeniden başlatma sonrası korunur
7. Cihaz değişimi ses kesintisi olmadan atlatılır
8. Bölüm 10'daki elle doğrulama kontrol listesinin yedi maddesi de geçer
9. `AudioDSP`, `Profiles` ve `Persistence` birim testleri geçer
10. Notarize edilmiş DMG üretilir ve temiz bir makinede çalışır

## 14. Kaynaklar

- [AudioHardwareCreateProcessTap, Apple Developer Documentation](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [AudioCap, sistem sesi yakalama örnek kodu, insidegui](https://github.com/insidegui/AudioCap)
- [Capturing System Audio on macOS in 2026, DGR Labs](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [macOS Still Has No Volume Mixer, So I Built One, Mimir](https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp)
