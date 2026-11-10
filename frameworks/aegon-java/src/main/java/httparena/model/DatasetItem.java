package httparena.model;

import java.util.List;

public final class DatasetItem {
    public long id;
    public String name;
    public String category;
    public long price;
    public long quantity;
    public boolean active;
    public List<String> tags;
    public Rating rating;

    public static final class Rating {
        public long score;
        public long count;

        public Rating() {}

        public Rating(long score, long count) {
            this.score = score;
            this.count = count;
        }
    }
}

