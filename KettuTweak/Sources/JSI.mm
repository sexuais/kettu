#import "KettuJSI.h"
#import "Logger.h"

using namespace facebook;

namespace {
class NSDataBuffer final : public jsi::Buffer {
public:
    explicit NSDataBuffer(NSData *data) : data_(data) {}
    size_t size() const override { return data_.length; }
    const uint8_t *data() const override {
        return static_cast<const uint8_t *>(data_.bytes);
    }
private:
    NSData *data_;
};

static BOOL looksLikeHermes(NSData *data) {
    if (!data || data.length < 4) return NO;
    const uint8_t *b = (const uint8_t *)data.bytes;
    return b[0] == 0xC6 && b[1] == 0x1F && b[2] == 0xBC && b[3] == 0x03;
}
}

@implementation KettuJSI

+ (void)evaluate:(NSData *)data
             tag:(NSString *)tag
         runtime:(jsi::Runtime &)runtime {
    if (!data.length) return;

    try {
        if (looksLikeHermes(data)) {
            auto buffer = std::make_shared<NSDataBuffer>(data);
            auto prepared = runtime.prepareJavaScript(
                buffer, std::string(tag.UTF8String ?: "kettu"));
            runtime.evaluatePreparedJavaScript(prepared);
        } else {
            std::string source(
                (const char *)data.bytes,
                data.length);
            auto buffer = std::make_shared<jsi::StringBuffer>(
                std::move(source));
            runtime.evaluateJavaScript(
                buffer,
                std::string(tag.UTF8String ?: "kettu"));
        }
    } catch (const jsi::JSError &e) {
        BunnyLog(@"[KettuJSI] JavaScript error in %@: %s", tag, e.what());
    } catch (const std::exception &e) {
        BunnyLog(@"[KettuJSI] C++ exception in %@: %s", tag, e.what());
    }
}

@end
