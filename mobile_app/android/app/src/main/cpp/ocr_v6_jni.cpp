#include "ocr_v6_engine.h"
#include <android/bitmap.h>
#include <android/log.h>
#include <jni.h>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
std::string Path(JNIEnv *env, jstring value) {
    if (!value)
        throw std::invalid_argument("Missing OCR asset path");
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars)
        throw std::runtime_error("Cannot read OCR path");
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}
void Fail(JNIEnv *env, const char *message) {
    if (!env->ExceptionCheck()) {
        jclass cls = env->FindClass("java/lang/IllegalStateException");
        if (cls) {
            env->ThrowNew(cls, message);
            env->DeleteLocalRef(cls);
        }
    }
}
jstring Text(JNIEnv *env, const std::string &utf8) {
    std::vector<jchar> chars;
    for (size_t i = 0; i < utf8.size();) {
        uint32_t code = static_cast<unsigned char>(utf8[i++]);
        int extra = 0;
        if (code >= 0xf0) {
            code &= 7;
            extra = 3;
        } else if (code >= 0xe0) {
            code &= 15;
            extra = 2;
        } else if (code >= 0xc0) {
            code &= 31;
            extra = 1;
        }
        if (i + extra > utf8.size())
            throw std::runtime_error("Invalid UTF-8 model dictionary");
        for (int j = 0; j < extra; ++j) {
            const auto next = static_cast<unsigned char>(utf8[i++]);
            if ((next & 0xc0) != 0x80)
                throw std::runtime_error("Invalid UTF-8 model dictionary");
            code = (code << 6) | (next & 63);
        }
        if (code > 0x10ffff)
            throw std::runtime_error("Invalid Unicode output");
        if (code >= 0x10000) {
            code -= 0x10000;
            chars.push_back(jchar(0xd800 + (code >> 10)));
            chars.push_back(jchar(0xdc00 + (code & 1023)));
        } else
            chars.push_back(jchar(code));
    }
    return env->NewString(chars.data(), static_cast<jsize>(chars.size()));
}
} // namespace
extern "C" JNIEXPORT jlong JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeCreate(JNIEnv *env, jobject, jstring det,
                                                                  jstring rec, jstring dictionary) {
    try {
        return reinterpret_cast<jlong>(
            new ppocrv6::Engine(Path(env, det), Path(env, rec), Path(env, dictionary), 2));
    } catch (const std::exception &e) {
        __android_log_print(ANDROID_LOG_ERROR, "PPOCRv6", "Initialization failed: %s", e.what());
        Fail(env, "PP-OCRv6_small 初始化失败，请检查模型文件");
        return 0;
    }
}
extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeProcess(JNIEnv *env, jobject,
                                                                   jlong handle, jobject bitmap,
                                                                   jlong timeoutMs) {
    void *pixels = nullptr;
    bool locked = false;
    try {
        if (!handle || !bitmap)
            throw std::invalid_argument("Invalid OCR request");
        AndroidBitmapInfo info{};
        if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
            info.format != ANDROID_BITMAP_FORMAT_RGBA_8888)
            throw std::invalid_argument("Expected RGBA bitmap");
        if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS)
            throw std::runtime_error("Cannot access image pixels");
        locked = true;
        auto *engine = reinterpret_cast<ppocrv6::Engine *>(handle);
        const auto results =
            engine->Process(static_cast<uint8_t *>(pixels), int(info.width), int(info.height),
                            int(info.stride), static_cast<int64_t>(timeoutMs));
        AndroidBitmap_unlockPixels(env, bitmap);
        locked = false;
        const auto &timing = engine->statistics();
        __android_log_print(ANDROID_LOG_DEBUG, "PPOCRv6",
                            "model=PP-OCRv6_small backend=ORT_CPU det_ms=%.1f rec_ms=%.1f "
                            "total_ms=%.1f lines=%zu det=%dx%d",
                            timing.detection_ms, timing.recognition_ms, timing.total_ms,
                            results.size(), timing.detector_width, timing.detector_height);
        jclass cls = env->FindClass("com/xcy/yuntuitui/inventory/ocr/NativeOcrResult");
        if (!cls)
            return nullptr;
        const auto constructor = env->GetMethodID(cls, "<init>", "(Ljava/lang/String;FFFFFF)V");
        if (!constructor) {
            env->DeleteLocalRef(cls);
            return nullptr;
        }
        auto array = env->NewObjectArray(static_cast<jsize>(results.size()), cls, nullptr);
        if (!array) {
            env->DeleteLocalRef(cls);
            return nullptr;
        }
        for (size_t i = 0; i < results.size() && !env->ExceptionCheck(); ++i) {
            const auto &result = results[i];
            auto text = Text(env, result.text);
            if (!text)
                break;
            auto object = env->NewObject(cls, constructor, text, result.confidence,
                                         result.box.center_x, result.box.center_y, result.box.width,
                                         result.box.height, result.box.angle);
            if (object) {
                env->SetObjectArrayElement(array, static_cast<jsize>(i), object);
                env->DeleteLocalRef(object);
            }
            env->DeleteLocalRef(text);
        }
        env->DeleteLocalRef(cls);
        return array;
    } catch (const std::exception &e) {
        if (locked)
            AndroidBitmap_unlockPixels(env, bitmap);
        __android_log_print(ANDROID_LOG_ERROR, "PPOCRv6", "Recognition failed: %s", e.what());
        Fail(env, "PP-OCRv6_small 识别失败，请重试或手工录入");
        return nullptr;
    }
}
extern "C" JNIEXPORT void JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeDestroy(JNIEnv *, jobject,
                                                                   jlong handle) {
    delete reinterpret_cast<ppocrv6::Engine *>(handle);
}
