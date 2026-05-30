# 保护 PaddleOCR 的 JNI 交互数据类及其所有构造函数和字段，防止 Release 模式下 R8 混淆裁剪导致 NoSuchMethodError
-keep class com.xcy.yuntuitui.inventory.ocr.NativeOcrResult {
    <fields>;
    <init>(...);
}

# 保护 PaddleOCR 引擎类的 Native C++ 映射方法
-keep class com.xcy.yuntuitui.inventory.ocr.PaddleOcrEngine {
    native <methods>;
}
