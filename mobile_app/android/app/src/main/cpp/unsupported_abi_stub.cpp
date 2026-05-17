#include <jni.h>

extern "C" {

JNIEXPORT void JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeSetCacheDir(
    JNIEnv *, jclass, jstring) {}

JNIEXPORT void JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeShutdown(
    JNIEnv *, jclass) {}

JNIEXPORT jlong JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeCreate(
    JNIEnv *, jobject, jstring, jstring, jstring, jint) {
  return 0;
}

JNIEXPORT jobjectArray JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeProcess(
    JNIEnv *, jobject, jlong, jobject) {
  return nullptr;
}

JNIEXPORT void JNICALL
Java_com_xcy_yuntuitui_inventory_ocr_PaddleOcrEngine_nativeDestroy(
    JNIEnv *, jobject, jlong) {}

}  // extern "C"
