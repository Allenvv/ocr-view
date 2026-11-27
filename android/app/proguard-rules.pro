# The ONNX Runtime native bridge looks up Java classes and members by literal name.
# Default R8 native-method rules alone don't keep those Java callback targets.
-keep class ai.onnxruntime.** { *; }
