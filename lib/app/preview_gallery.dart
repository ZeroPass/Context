import 'package:markdown/markdown.dart' as md;

import 'file_references.dart';

// Parse document order, not raw Markdown: link labels are not extra attachments.
List<String> previewReferences(String text) {
  final references = <String>{};
  void add(String source) {
    final path = FileReferenceResolver.clean(source);
    final uri = Uri.tryParse(path);
    if (uri?.scheme == 'http' || uri?.scheme == 'https') return;
    if (isWhiteboardPreview(path)) references.add(path);
  }

  void visit(md.Node node) {
    if (node is md.Element) {
      if (node.tag == 'a' || node.tag == 'img') {
        final source = node.attributes[node.tag == 'a' ? 'href' : 'src'];
        if (source != null) add(source);
        return;
      }
      if (node.tag == 'code' && !node.textContent.contains('\n')) {
        // Inline code often contains complete paths with spaces.
        add(node.textContent);
        if (isWhiteboardPreview(
          FileReferenceResolver.clean(node.textContent),
        )) {
          return;
        }
      }
      for (final child in node.children ?? <md.Node>[]) {
        visit(child);
      }
    } else if (node is md.Text) {
      for (final match in fileReferencePattern.allMatches(node.text)) {
        add(match[0]!.replaceFirst(RegExp(r'[.,;!?\)\]]+$'), ''));
      }
    }
  }

  for (final node in md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parseLines(text.split('\n'))) {
    visit(node);
  }
  return references.take(128).toList();
}

Future<List<String>> resolvePreviewGallery(
  String text,
  FileReferenceResolver resolver,
) async {
  final paths = <String>[];
  final seen = <String>{};
  for (final source in previewReferences(text)) {
    try {
      final resolved = await resolver.resolve(source);
      // Ambiguous locations still require the existing explicit chooser.
      if (resolved.paths.length != 1) continue;
      final path = resolved.paths.single;
      final identity = resolver.windows ? path.toLowerCase() : path;
      if (seen.add(identity) && isWhiteboardPreview(path)) paths.add(path);
    } on Object {
      // An inaccessible attachment must not prevent navigation to other files.
    }
  }
  return paths;
}
