class PhotoAsset {
  const PhotoAsset({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.modifiedAt,
    required this.sha256,
  });

  final int id;
  final String name;
  final String path;
  final int size;
  final DateTime? modifiedAt;
  final String sha256;

  factory PhotoAsset.fromMap(Map<String, Object?> map) => PhotoAsset(
    id: map['id']! as int,
    name: map['name']! as String,
    path: map['path']! as String,
    size: map['size']! as int,
    modifiedAt: map['modifiedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(map['modifiedAt']! as int),
    sha256: map['sha256']! as String,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'path': path,
    'size': size,
    'modifiedAt': modifiedAt?.millisecondsSinceEpoch,
    'sha256': sha256,
  };
}
