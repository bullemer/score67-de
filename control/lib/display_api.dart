typedef Api =
    Future<dynamic> Function(
      String path,
      String method,
      Map<String, dynamic>? body,
    );
