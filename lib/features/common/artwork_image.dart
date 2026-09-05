import 'package:flutter/material.dart';

class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.url,
    required this.fallbackColor,
    this.fit = BoxFit.cover,
    this.icon = Icons.movie_outlined,
  });

  final Uri? url;
  final Color fallbackColor;
  final BoxFit fit;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final value = url;
    if (value == null || !value.hasScheme || value.host.isEmpty) {
      return _fallback();
    }
    return Image.network(
      value.toString(),
      fit: fit,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, synchronouslyLoaded) {
        if (synchronouslyLoaded || frame != null) return child;
        return Stack(
          fit: StackFit.expand,
          children: [
            _fallback(),
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        );
      },
      errorBuilder: (_, _, _) => _fallback(),
    );
  }

  Widget _fallback() => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [fallbackColor, Color.lerp(fallbackColor, Colors.black, 0.7)!],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(child: Icon(icon, color: Colors.white70, size: 34)),
  );
}
