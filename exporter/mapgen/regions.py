from dataclasses import dataclass, field

PREFIX = 'sgm_skate3_'
LITE = (0.4, 2, 6.0)


@dataclass(frozen=True)
class Region:
    name: str
    title: str
    district: str
    corners: tuple = ()
    y_range: tuple = (-1.0e9, 1.0e9)
    spawn: tuple = ()
    spawn_heading: float = 0.0
    sky: str = 'sky_day01_01'
    sun: tuple = (-50.0, 30.0, 0.0)
    scenery: float = 120.0
    walls: bool = True
    skybox: bool = True
    backdrop: bool = True
    light_detail: tuple = ()
    vertex_lighting: bool = True
    extra: dict = field(default_factory=dict)

    @property
    def map_name(self):
        return PREFIX + self.name


REGIONS = [
    Region('maloof', 'Maloof Money Cup', 'DIST_MaloofMoneyCup'),
    Region('unibowl', 'University Bowl', 'DIST_University',
           corners=((255.0, 335.0), (475.0, 335.0), (475.0, 530.0), (255.0, 530.0)), backdrop=False),
    Region('ultramegapark', 'Super Ultra Mega Park', 'DIST_University',
           corners=((170.0, -830.0), (495.0, -830.0), (495.0, -540.0), (170.0, -540.0)), backdrop=False),
    Region('university', 'University Campus', 'DIST_University',
           corners=((-90.0, -490.0), (495.0, -490.0), (495.0, 90.0), (-90.0, 90.0)), backdrop=False,
           light_detail=LITE),
    Region('industrial', 'Industrial', 'DIST_Industrial',
           corners=((-605.0, 160.0), (8.0, 160.0), (2.0, -482.0), (-352.0, -549.0), (-508.0, -409.0)), backdrop=False,
           light_detail=LITE),
    Region('quarry', 'Quarry', 'DIST_Industrial',
           corners=((403.0, 202.0), (94.0, 202.0), (-48.0, 134.0), (-3.0, -103.0), (340.0, -180.0), (472.0, -81.0)),
           backdrop=False, light_detail=LITE),
    Region('skateschool', 'Skate School', 'DIST_SkateSchool',
           corners=((-205.0, -300.0), (505.0, -300.0), (505.0, 415.0), (-205.0, 415.0))),
    Region('blackbox', 'Black Box', 'DIST_BlackBoxPark'),
]


def by_name(name):
    name = name.removeprefix(PREFIX).removeprefix('sgm_')
    for region in REGIONS:
        if region.name == name:
            return region
    raise KeyError('no region named ' + name)
