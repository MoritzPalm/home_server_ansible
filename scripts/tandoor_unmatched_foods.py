# Foods and units that imports created outside the open data set, with how
# many recipes use them. Read-only. The output is the to-do list for the import
# rules in roles/kitchen/templates/tandoor_bootstrap.py.j2: add an alias for
# each spelling worth keeping, then merge the stray food into its open-data
# twin in the Tandoor UI (Foods list, select, Merge).
#
#   ssh moritzpalm@mserver 'docker exec -i -w /opt/recipes tandoor \
#       /opt/recipes/venv/bin/python manage.py shell' < scripts/tandoor_unmatched_foods.py

from django.db.models import Count, Q
from django_scopes import scopes_disabled

from cookbook.models import Food, Space, Unit

with scopes_disabled():
    # SOCIAL_DEFAULT_ACCESS and the bootstrap both use the lowest-id space.
    space = Space.objects.order_by('pk').first()
    stray = Q(open_data_slug__isnull=True) | Q(open_data_slug='')

    foods = (
        Food.objects.filter(space=space).filter(stray)
        .annotate(recipes=Count('ingredient__step__recipe', distinct=True))
        .order_by('-recipes', 'name')
    )
    units = (
        Unit.objects.filter(space=space).filter(stray)
        .annotate(ingredients=Count('ingredient', distinct=True))
        .order_by('-ingredients', 'name')
    )

    print(f'space: {space.name}')
    print(f'\nfoods outside the open data: {foods.count()}')
    print(f'{"recipes":>7}  {"food":<40} category')
    for f in foods:
        category = f.supermarket_category.name if f.supermarket_category else '-'
        print(f'{f.recipes:>7}  {f.name:<40} {category}')

    print(f'\nunits outside the open data: {units.count()}')
    print(f'{"uses":>7}  unit')
    for u in units:
        print(f'{u.ingredients:>7}  {u.name}')
