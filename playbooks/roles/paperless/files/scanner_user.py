# Run through `manage.py shell -c`. Ensures the API-only upload user exists with
# exactly the add_document permission and the token from the vault. Prints
# "changed" or "ok" as the last line for Ansible's changed_when.
import os

from django.contrib.auth.models import Permission
from django.contrib.auth.models import User
from rest_framework.authtoken.models import Token

username = os.environ["SCANNER_USER"]
key = os.environ["SCANNER_TOKEN"]
changed = False

user, created = User.objects.get_or_create(username=username)
# No password: the account authenticates by token only and cannot log in.
if created or user.has_usable_password():
    user.set_unusable_password()
    changed = True
if user.is_staff or user.is_superuser:
    user.is_staff = user.is_superuser = False
    changed = True
if changed:
    user.save()

add = Permission.objects.get(
    content_type__app_label="documents",
    codename="add_document",
)
if list(user.user_permissions.all()) != [add]:
    user.user_permissions.set([add])
    changed = True
if user.groups.exists():
    user.groups.clear()
    changed = True

if not Token.objects.filter(user=user, key=key).exists():
    Token.objects.filter(user=user).delete()
    Token.objects.create(user=user, key=key)
    changed = True

print("changed" if changed else "ok")
