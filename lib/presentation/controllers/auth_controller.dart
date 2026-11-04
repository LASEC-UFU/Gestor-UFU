import 'package:flutter/foundation.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/domain/repositories/i_moodle_repository.dart';

class AuthController extends ChangeNotifier {
  final IMoodleRepository _repo;

  AuthController(this._repo);

  MoodleCredential? _credential;
  bool _loading = false;
  String? _error;

  MoodleCredential? get credential => _credential;
  bool get loading => _loading;
  String? get error => _error;
  bool get isLoggedIn => _credential != null;
  String get baseUrl => _credential?.moodleUrl ?? '';
  String get token => _credential?.token ?? '';

  Future<void> init() async {
    _credential = await _repo.getSavedCredential();
    notifyListeners();
  }

  Future<bool> login(String baseUrl, String username, String password) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _credential = await _repo.login(baseUrl, username, password);
      await _repo.saveCredential(_credential!);
      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await _repo.clearCredential();
    _credential = null;
    notifyListeners();
  }
}
