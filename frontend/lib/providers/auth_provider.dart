import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_service.dart';
import 'package:frontend/models/user_model.dart';
import 'package:frontend/providers/home_provider.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hive/hive.dart';

final apiServiceProvider = Provider<ApiService>((ref) => ApiService());
final authProvider =
    StateNotifierProvider<AuthProvider, AuthState>((ref) => AuthProvider(ref));

class AuthState {
  final bool isLoading;
  final String? error;
  final User? user;
  final bool isAuthenticated;

  AuthState({this.isLoading = false, this.error, this.user})
      : isAuthenticated = user != null;

  AuthState copyWith({
    bool? isLoading,
    String? error,
    User? user,
    bool clearError = false,
    bool clearUser = false,
  }) {
    return AuthState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      user: clearUser ? null : (user ?? this.user),
    );
  }
}

class AuthProvider extends StateNotifier<AuthState> {
  final Ref _ref;
  late final ApiService _apiService;
  late final Box _appDataBox;
  late final GoogleSignIn _googleSignIn;

  AuthProvider(this._ref) : super(AuthState(isLoading: true)) {
    _apiService = _ref.read(apiServiceProvider);
    _appDataBox = Hive.box('app_data');
    _googleSignIn = GoogleSignIn(scopes: ['email']);
    _checkInitialAuthStatus();
  }

  Future<void> _checkInitialAuthStatus() async {
    final token = _appDataBox.get('accessToken');
    if (token != null) {
      await fetchUserProfile();
    } else {
      state = state.copyWith(isLoading: false, clearUser: true);
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  Future<void> fetchUserProfile() async {
    try {
      final response = await _apiService.getUserProfile();
      if (response.statusCode == 200) {
        final user = User.fromJson(jsonDecode(response.body));
        state = state.copyWith(isLoading: false, user: user, error: null);
      } else {
        await logout();
      }
    } catch (e) {
      state = state.copyWith(
          isLoading: false, error: e.toString(), clearUser: true);
    }
  }

  /// This is the simple, standard Google Sign-In flow for mobile.
  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      if (googleUser == null) {
        state = state.copyWith(isLoading: false); // User cancelled the sign-in
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final String? idToken = googleAuth.idToken;

      if (idToken == null) {
        throw Exception('Failed to get Google ID token.');
      }

      // Send the token to the backend endpoint we prepared
      final response = await _apiService.googleSignIn(idToken);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _appDataBox.put('accessToken', data['accessToken']);
        await fetchUserProfile();
        _ref.invalidate(homeProvider);
        _ref.invalidate(peakStatusProvider);
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(isLoading: false, error: errorData['message']);
        await _googleSignIn.signOut();
      }
    } catch (e) {
      state = state.copyWith(
          isLoading: false, error: "Sign-in failed. Please try again.");
      await _googleSignIn.signOut();
    }
  }

  Future<bool> register(String name, String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await _apiService.register(name, email, password);
      if (response.statusCode == 201) {
        state = state.copyWith(isLoading: false);
        return true;
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(
            isLoading: false,
            error: errorData['message'] ?? 'Registration failed.');
        return false;
      }
    } catch (e) {
      state = state.copyWith(
          isLoading: false, error: "Connection failed. Please try again.");
      return false;
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await _apiService.login(email, password);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _appDataBox.put('accessToken', data['accessToken']);
        await fetchUserProfile();
        _ref.invalidate(peakStatusProvider);
        _ref.invalidate(homeProvider);
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(isLoading: false, error: errorData['message']);
      }
    } catch (e) {
      state = state.copyWith(
          isLoading: false, error: "Connection failed. Please try again.");
    }
  }

  Future<bool> updateProvider(String provider) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await _apiService.updateUserProvider(provider);

      if (response.statusCode == 200) {
        final updatedUser = User.fromJson(jsonDecode(response.body));
        state = state.copyWith(isLoading: false, user: updatedUser);

        // This is the key fix: Invalidate the providers to force a clean refresh
        // on the home screen, preventing the 'disposed' error.
        _ref.invalidate(peakStatusProvider);
        _ref.invalidate(homeProvider);

        return true;
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(isLoading: false, error: errorData['message']);
        return false;
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<void> updateUser({String? name, String? avatarUrl}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response =
          await _apiService.updateUser(name: name, avatarUrl: avatarUrl);
      if (response.statusCode == 200) {
        final updatedUser = User.fromJson(jsonDecode(response.body));
        state = state.copyWith(isLoading: false, user: updatedUser);
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(isLoading: false, error: errorData['message']);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> updateNotificationPreference(bool isEnabled) async {
    if (state.user == null) return;
    final originalUser = state.user!;
    final optimisticUser = User(
      id: originalUser.id,
      email: originalUser.email,
      name: originalUser.name,
      provider: originalUser.provider,
      notificationsEnabled: isEnabled,
    );
    state = state.copyWith(user: optimisticUser);
    try {
      final response =
          await _apiService.updateNotificationPreferences(isEnabled);
      if (response.statusCode != 200) {
        state = state.copyWith(user: originalUser);
      }
    } catch (e) {
      state = state.copyWith(user: originalUser);
    }
  }

  Future<bool> changePassword(
      String currentPassword, String newPassword) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response =
          await _apiService.changePassword(currentPassword, newPassword);
      if (response.statusCode == 200) {
        state = state.copyWith(isLoading: false);
        return true;
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(isLoading: false, error: errorData['message']);
        return false;
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> verifyPassword(String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await _apiService.verifyPassword(password);
      if (response.statusCode == 200) {
        state = state.copyWith(isLoading: false);
        return true;
      } else {
        final errorData = jsonDecode(response.body);
        state = state.copyWith(isLoading: false, error: errorData['message']);
        return false;
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<void> logout() async {
    await _googleSignIn.signOut();
    await _appDataBox.clear();
    state = AuthState(user: null);
  }
}
