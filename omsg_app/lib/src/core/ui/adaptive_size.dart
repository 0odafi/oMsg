import 'package:flutter/material.dart';

extension AdaptiveSize on BuildContext {
  double sp(double value, {double min = 0.88, double max = 1.16}) {
    final width = MediaQuery.sizeOf(this).width;
    final scale = (width / 390).clamp(min, max).toDouble();
    return value * scale;
  }
}
