import 'package:flutter/material.dart';

/// Neumorphic design system — per the Orubus styleguide:
/// Primary #6BCEEC · focus #0DCFCC · border #E9E8E0 · surface #FFFFFF
/// radius 20 · layered soft shadows. Warm off-white canvas, light mode,
/// light from the top-left (soft-UI extruded cards).
class Neu {
  static const bg = Color(0xFFF0EFEB); // warm off-white canvas
  static const surface = Color(0xFFFFFFFF); // extruded white cards
  static const well = Color(0xFFEAE8E1); // pressed-in wells
  static const border = Color(0xFFE9E8E0); // styleguide border token
  static const shadowDark = Color(0xFFD8D3C7);
  static const shadowLight = Color(0xFFFFFFFF);
  static const accent = Color(0xFF6BCEEC);
  static const accentDeep = Color(0xFF2FA8CC);
  static const focus = Color(0xFF0DCFCC);
  static const ink = Color(0xFF26313F);
  static const inkSoft = Color(0xFF74869C);
  static const good = Color(0xFF2E9E5B);
  static const warn = Color(0xFFD98A1F);
  static const bad = Color(0xFFD64545);
  static const radius = 20.0;
}

/// Raised soft card: dual shadows (dark bottom-right, light top-left).
class NeuCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  const NeuCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.radius = Neu.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: Neu.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Neu.border, width: 1),
        boxShadow: const [
          BoxShadow(color: Neu.shadowDark, offset: Offset(6, 6), blurRadius: 14),
          BoxShadow(color: Neu.shadowLight, offset: Offset(-6, -6), blurRadius: 14),
        ],
      ),
      child: child,
    );
  }
}

/// Pressed-in well: inputs, log panels, screens-within-the-screen.
class NeuInset extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  const NeuInset({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin,
    this.radius = Neu.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: Neu.well,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Neu.border, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x99D8D3C7), offset: Offset(5, 5), blurRadius: 10),
          BoxShadow(color: Neu.shadowLight, offset: Offset(-5, -5), blurRadius: 10),
        ],
      ),
      child: child,
    );
  }
}

/// Soft raised button with a press-down animation.
class NeuButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? fill;
  final Color? textColor;
  final bool small;
  const NeuButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.fill,
    this.textColor,
    this.small = false,
  });

  @override
  State<NeuButton> createState() => _NeuButtonState();
}

class _NeuButtonState extends State<NeuButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final fill = widget.fill ?? Neu.surface;
    final fg = widget.textColor ?? Neu.ink;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        padding: EdgeInsets.symmetric(
            vertical: widget.small ? 9 : 14,
            horizontal: widget.small ? 14 : 18),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Neu.radius),
          boxShadow: enabled
              ? (_down
                  ? const [
                      BoxShadow(color: Color(0x77A9B6C9), offset: Offset(2, 2), blurRadius: 4),
                      BoxShadow(color: Neu.shadowLight, offset: Offset(-2, -2), blurRadius: 4),
                    ]
                  : [
                      BoxShadow(
                          color: fill == Neu.surface
                              ? Neu.shadowDark
                              : Neu.accentDeep,
                          offset: const Offset(5, 5),
                          blurRadius: 12),
                      const BoxShadow(
                          color: Neu.shadowLight,
                          offset: Offset(-5, -5),
                          blurRadius: 12),
                    ])
              : const [],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          if (widget.icon != null) ...[
            Icon(widget.icon,
                size: widget.small ? 16 : 19,
                color: enabled ? fg : Neu.inkSoft),
            SizedBox(width: widget.small ? 6 : 8),
          ],
          Text(widget.label,
              style: TextStyle(
                  fontSize: widget.small ? 12.5 : 14.5,
                  fontWeight: FontWeight.w600,
                  color: enabled ? fg : Neu.inkSoft)),
        ]),
      ),
    );
  }
}

/// Circular icon button (hamburger, three-dots, send).
class NeuIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? iconColor;
  final double size;
  const NeuIconBtn(this.icon, {super.key, this.onTap, this.iconColor, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Neu.surface,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Neu.shadowDark, offset: Offset(3, 3), blurRadius: 7),
              BoxShadow(color: Neu.shadowLight, offset: Offset(-3, -3), blurRadius: 7),
            ],
          ),
          child: Icon(icon, size: size * 0.5, color: iconColor ?? Neu.ink),
        ),
      ),
    );
  }
}

/// Small status pill (PAIRED / WAITING / OFFLINE …).
class NeuPill extends StatelessWidget {
  final String label;
  final Color color;
  const NeuPill(this.label, {super.key, this.color = Neu.inkSoft});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Neu.well,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35), width: 1),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: color)),
    );
  }
}

/// Section label above cards (styleguide caption tier).
class NeuSection extends StatelessWidget {
  final String text;
  const NeuSection(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(text.toUpperCase(),
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: Neu.inkSoft)),
    );
  }
}
